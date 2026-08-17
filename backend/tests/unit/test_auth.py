import logging
from collections.abc import Callable, Iterator
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import Depends, FastAPI, HTTPException
from fastapi.testclient import TestClient

from constants import TEST_API_CLIENT_ID, TEST_TENANT_ID
from cost_copilot.auth import (
    EntraSigningKeyResolver,
    get_signing_key_resolver,
    require_cost_reader,
)
from cost_copilot.config import get_settings
from cost_copilot.errors import FORBIDDEN_ROLE_DETAIL

SigningKeyResolverStub = Callable[[str], str]


@pytest.fixture(scope="session")
def rsa_key_pair() -> tuple[str, str]:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    public_pem = (
        private_key.public_key()
        .public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        .decode()
    )
    return private_pem, public_pem


def build_claims(**overrides: Any) -> dict[str, Any]:
    now = datetime.now(tz=UTC)
    claims: dict[str, Any] = {
        "iss": f"https://login.microsoftonline.com/{TEST_TENANT_ID}/v2.0",
        "aud": TEST_API_CLIENT_ID,
        "tid": TEST_TENANT_ID,
        "ver": "2.0",
        "oid": "11111111-2222-3333-4444-555555555555",
        "roles": ["Cost.Read"],
        "iat": now,
        "nbf": now,
        "exp": now + timedelta(minutes=5),
    }
    claims.update(overrides)
    return {key: value for key, value in claims.items() if value is not None}


@pytest.fixture
def protected_client(rsa_key_pair: tuple[str, str]) -> Iterator[TestClient]:
    _, public_pem = rsa_key_pair
    app = build_protected_app(lambda _token: public_pem)
    with TestClient(app) as client:
        yield client


def build_protected_app(resolver: SigningKeyResolverStub) -> FastAPI:
    app = FastAPI()

    @app.get("/protected")
    def protected(
        claims: Annotated[dict[str, Any], Depends(require_cost_reader)],
    ) -> dict[str, Any]:
        return {"roles": claims["roles"], "oid": claims["oid"]}

    app.dependency_overrides[get_signing_key_resolver] = lambda: resolver
    return app


def encode(private_pem: str, **overrides: Any) -> str:
    return jwt.encode(build_claims(**overrides), private_pem, algorithm="RS256")


def assert_unauthorized(response: Any) -> None:
    assert response.status_code == 401
    assert response.headers["www-authenticate"] == "Bearer"
    assert response.json() == {"detail": "Invalid or expired access token"}


def test_cost_reader_role_is_required() -> None:
    with pytest.raises(HTTPException) as error:
        require_cost_reader({"roles": ["Other.Role"]})

    assert error.value.status_code == 403
    assert error.value.detail == FORBIDDEN_ROLE_DETAIL


def test_cost_reader_role_is_returned_unchanged() -> None:
    claims = {"roles": ["Cost.Read"], "oid": "abc"}

    assert require_cost_reader(claims) == claims


def test_valid_token_with_cost_reader_role_is_accepted(
    protected_client: TestClient, rsa_key_pair: tuple[str, str]
) -> None:
    private_pem, _ = rsa_key_pair

    response = protected_client.get(
        "/protected",
        headers={"Authorization": f"Bearer {encode(private_pem)}"},
    )

    assert response.status_code == 200
    assert response.json()["roles"] == ["Cost.Read"]


def test_valid_token_without_cost_reader_role_is_forbidden(
    protected_client: TestClient, rsa_key_pair: tuple[str, str]
) -> None:
    private_pem, _ = rsa_key_pair

    response = protected_client.get(
        "/protected",
        headers={"Authorization": f"Bearer {encode(private_pem, roles=['Other.Role'])}"},
    )

    assert response.status_code == 403
    assert response.json() == {"detail": "Cost.Read role is required"}


def test_missing_authorization_header_is_unauthorized(protected_client: TestClient) -> None:
    assert_unauthorized(protected_client.get("/protected"))


def test_non_bearer_scheme_is_unauthorized(protected_client: TestClient) -> None:
    assert_unauthorized(
        protected_client.get("/protected", headers={"Authorization": "Basic dXNlcjpwYXNz"})
    )


def test_malformed_token_is_unauthorized(protected_client: TestClient) -> None:
    assert_unauthorized(
        protected_client.get("/protected", headers={"Authorization": "Bearer not-a-jwt"})
    )


@pytest.mark.parametrize(
    "overrides",
    [
        pytest.param({"exp": datetime.now(tz=UTC) - timedelta(minutes=5)}, id="expired"),
        pytest.param({"exp": None}, id="missing-exp"),
        pytest.param({"tid": None}, id="missing-tid"),
        pytest.param({"tid": "99999999-9999-9999-9999-999999999999"}, id="tenant-mismatch"),
        pytest.param({"aud": "another-api"}, id="wrong-audience"),
        pytest.param({"iss": "https://evil.example/v2.0"}, id="wrong-issuer"),
        pytest.param({"ver": None}, id="missing-version"),
        pytest.param({"ver": "1.0"}, id="v1-token"),
        pytest.param({"oid": None}, id="missing-object-id"),
        pytest.param({"nonce": "6f1c"}, id="id-token-shaped"),
    ],
)
def test_rejected_tokens_are_unauthorized(
    protected_client: TestClient, rsa_key_pair: tuple[str, str], overrides: dict[str, Any]
) -> None:
    private_pem, _ = rsa_key_pair
    credential = encode(private_pem, **overrides)

    response = protected_client.get("/protected", headers={"Authorization": f"Bearer {credential}"})

    assert_unauthorized(response)
    assert credential not in response.text


def test_token_signed_by_an_unknown_key_is_unauthorized(
    protected_client: TestClient, rsa_key_pair: tuple[str, str]
) -> None:
    _, public_pem = rsa_key_pair
    other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    other_pem = other_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode()
    assert other_pem != public_pem

    assert_unauthorized(
        protected_client.get(
            "/protected",
            headers={"Authorization": f"Bearer {encode(other_pem)}"},
        )
    )


def test_unsigned_token_is_unauthorized(protected_client: TestClient) -> None:
    credential = jwt.encode(build_claims(), key="", algorithm="none")

    assert_unauthorized(
        protected_client.get("/protected", headers={"Authorization": f"Bearer {credential}"})
    )


def test_signing_key_lookup_failure_does_not_leak_details(
    rsa_key_pair: tuple[str, str],
) -> None:
    private_pem, _ = rsa_key_pair

    def failing_resolver(_token: str) -> str:
        raise RuntimeError("jwks fetch failed for https://internal.example/keys")

    with TestClient(build_protected_app(failing_resolver)) as client:
        response = client.get(
            "/protected",
            headers={"Authorization": f"Bearer {encode(private_pem)}"},
        )

    assert_unauthorized(response)
    assert "jwks" not in response.text
    assert "internal.example" not in response.text


def test_default_signing_key_resolver_targets_the_configured_tenant() -> None:
    resolver = get_signing_key_resolver(get_settings())

    assert isinstance(resolver, EntraSigningKeyResolver)
    assert resolver.jwks_uri == (
        f"https://login.microsoftonline.com/{TEST_TENANT_ID}/discovery/v2.0/keys"
    )


def test_signing_key_failure_is_logged_without_token_or_exception_text(
    rsa_key_pair: tuple[str, str], caplog: pytest.LogCaptureFixture
) -> None:
    private_pem, _ = rsa_key_pair
    credential = encode(private_pem)

    def failing_resolver(_token: str) -> str:
        raise RuntimeError("jwks fetch failed for https://internal.example/keys")

    with caplog.at_level(logging.INFO), TestClient(build_protected_app(failing_resolver)) as client:
        client.get("/protected", headers={"Authorization": f"Bearer {credential}"})

    assert "Signing key lookup failed (RuntimeError)" in caplog.text
    assert "internal.example" not in caplog.text
    assert credential not in caplog.text


def test_rejected_token_is_logged_without_the_token(
    protected_client: TestClient, rsa_key_pair: tuple[str, str], caplog: pytest.LogCaptureFixture
) -> None:
    private_pem, _ = rsa_key_pair
    credential = encode(private_pem, aud="another-api")

    with caplog.at_level(logging.INFO):
        protected_client.get("/protected", headers={"Authorization": f"Bearer {credential}"})

    assert "Access token rejected" in caplog.text
    assert credential not in caplog.text
