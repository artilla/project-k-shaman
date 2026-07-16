"""Google/Kakao OAuth 프로토콜을 구현하는 고정 도메인 네트워크 어댑터."""

from __future__ import annotations

import json
import os
import urllib.request
from dataclasses import dataclass, field
from urllib.parse import urlencode


@dataclass(frozen=True)
class Provider:
    client_id: str | None
    client_secret: str | None = field(repr=False)
    authorize_url: str
    token_url: str
    userinfo_url: str
    scope: str


class HttpOAuthGateway:
    def __init__(self, providers: dict[str, Provider]) -> None:
        self.providers = providers

    @classmethod
    def from_env(cls) -> "HttpOAuthGateway":
        return cls(
            {
                "google": Provider(
                    client_id=os.getenv("GOOGLE_CLIENT_ID"),
                    client_secret=os.getenv("GOOGLE_CLIENT_SECRET"),
                    authorize_url="https://accounts.google.com/o/oauth2/v2/auth",
                    token_url="https://oauth2.googleapis.com/token",
                    userinfo_url="https://openidconnect.googleapis.com/v1/userinfo",
                    scope="openid email profile",
                ),
                "kakao": Provider(
                    client_id=os.getenv("KAKAO_REST_API_KEY"),
                    client_secret=os.getenv("KAKAO_CLIENT_SECRET"),
                    authorize_url="https://kauth.kakao.com/oauth/authorize",
                    token_url="https://kauth.kakao.com/oauth/token",
                    userinfo_url="https://kapi.kakao.com/v2/user/me",
                    scope="profile_nickname",
                ),
            }
        )

    def has_provider(self, provider: str) -> bool:
        return provider in self.providers

    def provider_status(self) -> dict[str, bool]:
        return {name: bool(config.client_id) for name, config in self.providers.items()}

    def authorize_url(
        self, provider: str, *, redirect_uri: str, state: str
    ) -> str | None:
        config = self.providers.get(provider)
        if not config or not config.client_id:
            return None
        params = {
            "client_id": config.client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": config.scope,
            "state": state,
        }
        return f"{config.authorize_url}?{urlencode(params)}"

    def exchange_profile(self, provider: str, code: str, *, redirect_uri: str) -> dict:
        config = self.providers[provider]
        body = urlencode(
            {
                "grant_type": "authorization_code",
                "client_id": config.client_id or "",
                "client_secret": config.client_secret or "",
                "redirect_uri": redirect_uri,
                "code": code,
            }
        ).encode()
        request = urllib.request.Request(config.token_url, data=body, method="POST")
        with urllib.request.urlopen(request, timeout=10) as response:  # noqa: S310
            token = json.loads(response.read())
        profile_request = urllib.request.Request(
            config.userinfo_url,
            headers={"Authorization": f"Bearer {token.get('access_token', '')}"},
        )
        with urllib.request.urlopen(profile_request, timeout=10) as response:  # noqa: S310
            profile = json.loads(response.read())
        return extract_profile(provider, profile)


def extract_profile(provider: str, profile: dict) -> dict:
    if provider == "google":
        return {
            "subject": profile.get("sub"),
            "nickname": profile.get("name") or profile.get("given_name"),
        }
    if provider == "kakao":
        subject = profile.get("id")
        nickname = profile.get("kakao_account", {}).get("profile", {}).get("nickname")
        return {
            "subject": str(subject) if subject is not None else None,
            "nickname": nickname,
        }
    return {"subject": None, "nickname": None}
