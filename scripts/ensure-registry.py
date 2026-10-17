#!/usr/bin/env python3
"""Create or reuse a private BASIC registry; print only its verified UUID."""

import json
import os
import sys
import time
import uuid
from http.client import HTTPException
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

IAM_URL = "https://iam.api.cloud.ru/api/v1/auth/token"
API_URL = "https://ar.api.cloud.ru"


class RegistryError(Exception):
    pass


class ApiError(RegistryError):
    def __init__(self, message, uncertain=False):
        super().__init__(message)
        self.uncertain = uncertain


def request_json(method, url, body=None, token=None, timeout=30):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    payload = None if body is None else json.dumps(body).encode()
    try:
        with urlopen(Request(url, data=payload, headers=headers, method=method), timeout=timeout) as response:
            result = json.load(response)
    except HTTPError as error:
        raise ApiError(f"Cloud.ru API: HTTP {error.code}.", uncertain=error.code >= 500) from None
    except (URLError, OSError, HTTPException):
        raise ApiError("Не удалось получить ответ Cloud.ru API.", uncertain=True) from None
    except (ValueError, UnicodeError):
        raise ApiError("Cloud.ru API вернул некорректный JSON.", uncertain=True) from None
    if not isinstance(result, dict):
        raise ApiError("Cloud.ru API вернул неожиданный формат ответа.", uncertain=True)
    return result


def registry_uuid(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise RegistryError("Cloud.ru API не вернул корректный UUID реестра.") from None


def ensure_registry(project_id, name, request):
    deadline = time.monotonic() + 180
    expected = {"name": name, "isPublic": False, "registryType": "DOCKER",
                "registryMode": "REGISTRY_MODE_LOCAL", "tariff": "BASIC"}

    def api(method, path, body=None):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RegistryError("Истекло ожидание реестра (180 секунд). Проверьте состояние перед повторным запуском.")
        return request(method, path, body, timeout=min(30, remaining))

    def pause():
        time.sleep(min(2, max(0, deadline - time.monotonic())))

    def validate(item):
        for field, value in expected.items():
            if item.get(field) != value:
                raise RegistryError(f"Существующий реестр не соответствует требуемому параметру {field}.")
        return registry_uuid(item.get("id"))

    def find_existing():
        params = {"projectId": project_id, "pageSize": 100}
        while True:
            page = api("GET", "/v1/registries?" + urlencode(params))
            items = page.get("registries", [])
            if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
                raise RegistryError("Cloud.ru API вернул некорректный список реестров.")
            for item in items:
                if item.get("name") == name:
                    validate(item)
                    return item
            if not page.get("nextPageToken"):
                return None
            params["pageToken"] = page["nextPageToken"]

    existing = find_existing()
    if existing is not None:
        resource_id = validate(existing)
    else:
        try:
            operation = api("POST", "/v1/registries", {"projectId": project_id, **expected})
        except ApiError as error:
            if not error.uncertain:
                raise
            try:
                existing = find_existing()
            except RegistryError:
                raise RegistryError("Исход создания неизвестен; чтение состояния не удалось. Повторный POST не отправлен.") from None
            if existing is None:
                raise RegistryError("Исход создания неизвестен; реестр пока не найден. Повторный POST не отправлен.") from None
            resource_id = validate(existing)
        else:
            resource_id = operation.get("resourceId")
            while True:
                if operation.get("error"):
                    raise RegistryError("Операция создания реестра завершилась ошибкой Cloud.ru.")
                if operation.get("done") is True:
                    break
                operation_id = operation.get("id")
                if not isinstance(operation_id, str) or not operation_id:
                    raise RegistryError("Cloud.ru API не вернул идентификатор операции. Проверьте состояние реестра.")
                pause()
                operation = api("GET", "/v1/operations/" + quote(operation_id, safe=""))
                resource_id = operation.get("resourceId") or resource_id
            if not resource_id:
                existing = find_existing()
                if existing is None:
                    raise RegistryError("Операция завершена, но UUID реестра не найден.")
                resource_id = validate(existing)
            resource_id = registry_uuid(resource_id)

    path = f"/v1/registries/{resource_id}?" + urlencode({"projectId": project_id})
    while True:
        item = api("GET", path)
        if validate(item) != resource_id:
            raise RegistryError("Cloud.ru API вернул другой реестр.")
        if item.get("status") == "ACTIVE":
            return resource_id
        if item.get("status") != "CREATING":
            raise RegistryError("Реестр не активен: ошибка или неизвестный статус Cloud.ru.")
        pause()


def main():
    try:
        config = json.load(sys.stdin)
        project_id = str(uuid.UUID(config["project_id"]))
        name = config["name"]
        if not isinstance(name, str) or not name.strip():
            raise ValueError()
        key_id, secret = os.environ["AUTH_KEY_ID"], os.environ["AUTH_SECRET"]
        if not key_id or not secret:
            raise ValueError()
        token = request_json("POST", IAM_URL, {"keyId": key_id, "secret": secret}).get("access_token")
        if not isinstance(token, str) or not token:
            raise RegistryError("IAM не вернул access_token.")

        def request(method, path, body=None, timeout=30):
            return request_json(method, API_URL + path, body, token, timeout)

        print(ensure_registry(project_id, name, request))
        return 0
    except RegistryError as error:
        print(str(error), file=sys.stderr)
    except (ValueError, KeyError, TypeError, AttributeError):
        print("Нужны JSON с project_id/name и непустые AUTH_KEY_ID/AUTH_SECRET в окружении.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
