from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"expected block not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


# Windows PowerShell 5.1 is stricter around piping directly from an expandable
# here-string terminator. Keep the TOML payload in a variable, then write it.
install = Path("install.ps1")
replace_once(install, '\n@"\nschema_version = 4\n', '\n$PolicyText = @"\nschema_version = 4\n')
replace_once(
    install,
    'auto_install = $UpdateAutoInstall\n"@ | ForEach-Object { Write-Utf8NoBom $Policy $_ }',
    'auto_install = $UpdateAutoInstall\n"@\nWrite-Utf8NoBom $Policy $PolicyText',
)

# A legacy source checkout can legitimately be detached (notably CI and archive
# bootstrap scenarios). Do not guess a branch in that state: reinstall the
# current source snapshot. Normal branch checkouts still fast-forward from their
# configured remote before reinstalling.
updater = Path("scripts/updater.py")
old = '''    try:\n        subprocess.run(["git", "-C", str(src), "pull", "--ff-only"], check=True)\n        if os.name == "nt":\n            subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(src / "install.ps1")], check=True)\n        else:\n            subprocess.run(["bash", str(src / "install.sh")], check=True)\n        return 0\n    except (OSError, subprocess.CalledProcessError):\n        return 2\n'''
new = '''    try:\n        branch = subprocess.check_output(\n            ["git", "-C", str(src), "rev-parse", "--abbrev-ref", "HEAD"],\n            text=True,\n            stderr=subprocess.DEVNULL,\n        ).strip()\n        if branch and branch != "HEAD":\n            remote = subprocess.run(\n                ["git", "-C", str(src), "config", "--get", f"branch.{branch}.remote"],\n                check=False,\n                stdout=subprocess.PIPE,\n                stderr=subprocess.DEVNULL,\n                text=True,\n            ).stdout.strip() or "origin"\n            subprocess.run(["git", "-C", str(src), "pull", "--ff-only", remote, branch], check=True)\n        if os.name == "nt":\n            subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(src / "install.ps1")], check=True)\n        else:\n            subprocess.run(["bash", str(src / "install.sh")], check=True)\n        return 0\n    except (OSError, subprocess.CalledProcessError):\n        return 2\n'''
replace_once(updater, old, new)

# Regression: detached HEAD must not attempt an ambiguous git pull.
tests = Path("tests/test_updater.py")
needle = '''\n\nif __name__ == "__main__":\n    unittest.main()\n'''
test_block = '''\n    def test_legacy_update_detached_checkout_reinstalls_without_pull(self) -> None:\n        source = self.root / "source"\n        (source / ".git").mkdir(parents=True)\n        (source / ("install.ps1" if os.name == "nt" else "install.sh")).write_text("fixture\\n", encoding="utf-8")\n        (self.state / "source").write_text(str(source) + "\\n", encoding="utf-8")\n        with patch.object(updater.subprocess, "check_output", return_value="HEAD\\n"), \\\n             patch.object(updater.subprocess, "run") as run:\n            run.return_value.returncode = 0\n            result = updater._legacy_git_update()\n        self.assertEqual(result, 0)\n        commands = [call.args[0] for call in run.call_args_list]\n        self.assertFalse(any("pull" in command for command in commands))\n        self.assertTrue(any(("install.ps1" in " ".join(command)) or ("install.sh" in " ".join(command)) for command in commands))\n\n\nif __name__ == "__main__":\n    unittest.main()\n'''
replace_once(tests, needle, "\n" + test_block)
