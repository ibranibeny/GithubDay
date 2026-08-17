"""Entra ID bearer token validation and app-role authorization."""

from functools import lru_cache
from typing import Annotated, Any, Protocol

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient
from jwt.exceptions import PyJWTError

from cost_copilot.config import Settings, get_settings
from cost_copilot.errors import unauthorized_error

COST_READER_ROLE = "Cost.Read"
ALLOWED_ALGORITHMS = ["RS256"]
REQUIRED_CLAIMS = ["exp", "tid", "aud", "iss"]

bearer_scheme = HTTPBearer(auto_error=False)


class SigningKeyResolver(Protocol):
    """Maps a raw token to the PEM/key material that signed it."""

    def __call__(self, token: str) -> Any: ...


class EntraSigningKeyResolver:
    """Fetches signing keys from the tenant JWKS endpoint."""

    def __init__(self, tenant_id: str) -> None:
        self.jwks_uri = f"https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys"
        self._client = PyJWKClient(self.jwks_uri, cache_keys=True)

    def __call__(self, token: str) -> Any:
        return self._client.get_signing_key_from_jwt(token).key


@lru_cache
def _resolver_for_tenant(tenant_id: str) -> EntraSigningKeyResolver:
    return EntraSigningKeyResolver(tenant_id)


def get_signing_key_resolver(
    settings: Annotated[Settings, Depends(get_settings)],
) -> SigningKeyResolver:
    """Dependency seam: override this to avoid network access in tests."""
    return _resolver_for_tenant(settings.azure_tenant_id)


def issuer_for(tenant_id: str) -> str:
    return f"https://login.microsoftonline.com/{tenant_id}/v2.0"


def verify_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    settings: Annotated[Settings, Depends(get_settings)],
    resolve_signing_key: Annotated[SigningKeyResolver, Depends(get_signing_key_resolver)],
) -> dict[str, Any]:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthorized_error()

    try:
        signing_key = resolve_signing_key(credentials.credentials)
    except Exception as error:  # JWKS lookup failures must not surface to callers.
        raise unauthorized_error() from error

    try:
        claims: dict[str, Any] = jwt.decode(
            credentials.credentials,
            signing_key,
            algorithms=ALLOWED_ALGORITHMS,
            audience=settings.entra_api_client_id,
            issuer=issuer_for(settings.azure_tenant_id),
            options={"require": REQUIRED_CLAIMS, "verify_signature": True},
        )
    except PyJWTError as error:
        raise unauthorized_error() from error

    if claims.get("tid") != settings.azure_tenant_id:
        raise unauthorized_error()
    return claims


def require_cost_reader(
    claims: Annotated[dict[str, Any], Depends(verify_token)],
) -> dict[str, Any]:
    roles = claims.get("roles", [])
    if not isinstance(roles, list) or COST_READER_ROLE not in roles:
        raise HTTPException(status_code=403, detail="Cost.Read role is required")
    return claims


CostReaderClaims = Annotated[dict[str, Any], Depends(require_cost_reader)]
