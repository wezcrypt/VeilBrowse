import io
import os
import sys

import pytest

from wezcrypt_backup.cli import main
from wezcrypt_backup.config import ConfigError, Settings


def env(monkeypatch, tmp_path):
    pepper = tmp_path / "pepper"
    assert main(["generate-pepper", str(pepper)]) == 0
    monkeypatch.setenv("WZC_BACKUP_TOKEN_PEPPER_FILE", str(pepper))
    monkeypatch.setenv("WZC_BACKUP_STORAGE_ROOT", str(tmp_path / "iphone-backups"))
    monkeypatch.setenv("WZC_BACKUP_STATE_DIR", str(tmp_path / "state"))
    return pepper


def test_admin_flow(monkeypatch, tmp_path, capsys):
    pepper = env(monkeypatch, tmp_path)
    assert (pepper.stat().st_mode & 0o777) == 0o600
    with pytest.raises(SystemExit):
        main(["generate-pepper", str(pepper)])
    assert main(["migrate"]) == 0
    monkeypatch.setattr(sys, "stdin", io.StringIO("a very long password 123\n"))
    assert main(["create-user", "alice", "--password-stdin", "--quota-gb", "50"]) == 0
    assert main(["create-api-key", "alice", "--label", "phone"]) == 0
    key = capsys.readouterr().out.strip().splitlines()[-1]
    assert key.startswith("wzk_")
    assert main(["users"]) == 0
    assert '"alice"' in capsys.readouterr().out
    assert main(["revoke-api-keys", "alice"]) == 0
    assert main(["purge"]) == 0
    backups = tmp_path / "b"
    backups.mkdir()
    assert main(["backup-db", str(backups)]) == 0
    assert len(list(backups.iterdir())) == 1


def test_insecure_pepper_permissions_refused(monkeypatch, tmp_path):
    pepper = env(monkeypatch, tmp_path)
    pepper.chmod(0o644)
    with pytest.raises(ConfigError):
        Settings.from_env()


def test_missing_pepper(monkeypatch, capsys):
    monkeypatch.delenv("WZC_BACKUP_TOKEN_PEPPER_FILE", raising=False)
    assert main(["migrate"]) == 2
