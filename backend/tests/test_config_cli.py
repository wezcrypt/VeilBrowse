import base64
import os

import pytest

from wezcrypt_mobile.cli import main
from wezcrypt_mobile.config import ConfigError, MobileSettings, parse_keyring


def test_parse_keyring_formats():
    key = os.urandom(32)
    ring = parse_keyring(f"# comment\n{base64.b64encode(key).decode()}\n2:{key.hex()}\n", "test")
    assert ring == {1: key, 2: key}
    with pytest.raises(ConfigError):
        parse_keyring("1:short", "test")
    with pytest.raises(ConfigError):
        parse_keyring("", "test")


def test_from_env_and_permissions(tmp_path, monkeypatch):
    key_file = tmp_path / "keys"
    assert main(["generate-key", str(key_file)]) == 0
    assert (key_file.stat().st_mode & 0o777) == 0o600
    with pytest.raises(SystemExit):
        main(["generate-key", str(key_file)])

    monkeypatch.setenv("WZC_MOBILE_MASTER_KEY_FILE", str(key_file))
    monkeypatch.setenv("WZC_MOBILE_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("WZC_MOBILE_ALLOWED_TELEGRAM_IDS", "1, 2")
    settings = MobileSettings.from_env()
    assert settings.allowed_telegram_ids == frozenset({1, 2})
    assert "master_keys" not in repr(settings) or "b'" not in repr(settings)

    key_file.chmod(0o644)
    with pytest.raises(ConfigError):
        MobileSettings.from_env()


def test_migrate_and_backup(tmp_path, monkeypatch):
    key_file = tmp_path / "keys"
    main(["generate-key", str(key_file)])
    monkeypatch.setenv("WZC_MOBILE_MASTER_KEY_FILE", str(key_file))
    monkeypatch.setenv("WZC_MOBILE_DATA_DIR", str(tmp_path / "data"))
    assert main(["migrate"]) == 0
    assert main(["migrate"]) == 0
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    assert main(["backup", str(backup_dir)]) == 0
    assert len(list(backup_dir.iterdir())) == 1
    assert main(["purge"]) == 0


def test_missing_key_is_config_error(monkeypatch, capsys):
    monkeypatch.delenv("WZC_MOBILE_MASTER_KEY_FILE", raising=False)
    assert main(["migrate"]) == 2
    assert "WZC_MOBILE_MASTER_KEY_FILE" in capsys.readouterr().err
