from __future__ import annotations

import io
import json
import struct
import subprocess
import threading
import zlib
import zipfile
from pathlib import Path

import pytest

from scripts import pets


def png_bytes(width: int, height: int) -> bytes:
    rows = b"".join(b"\x00" + bytes(width * 4) for _ in range(height))
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def webp_vpx_bytes(width: int, height: int) -> bytes:
    header = b"\x00\x00\x00\x00" + (width - 1).to_bytes(3, "little") + (height - 1).to_bytes(3, "little")
    vp8x = b"VP8X" + struct.pack("<I", len(header)) + header
    frame = b"\x00\x00\x00\x9d\x01\x2a" + struct.pack("<HH", width, height)
    vp8 = b"VP8 " + struct.pack("<I", len(frame)) + frame
    body = vp8x + vp8
    return b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WEBP" + body


def write_pack(root: Path, *, pet_id: str = "boba", version: int = 2, image: str = "png", display: str = "Boba") -> Path:
    root.mkdir(parents=True, exist_ok=True)
    name = f"spritesheet.{image}"
    metadata = {
        "id": pet_id,
        "displayName": display,
        "description": "test pet",
        "spriteVersionNumber": version,
        "spritesheetPath": name,
    }
    (root / "pet.json").write_text(json.dumps(metadata), encoding="utf-8")
    png_height = 143 if version == 2 else 117
    payload = png_bytes(96, png_height) if image == "png" else webp_vpx_bytes(1536, 2288)
    (root / name).write_bytes(payload)
    return root


def test_local_v2_directory_install_stages_intact_pack_and_activates(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source")

    result = pets.install_local(source, home=tmp_path / "home")

    assert result["id"] == "local-boba"
    installed = tmp_path / "home/codex-flow/pets/installed/local-boba"
    assert (installed / "pet.json").exists()
    assert (installed / "spritesheet.png").read_bytes() == (source / "spritesheet.png").read_bytes()
    assert pets.read_current(tmp_path / "home") == "local-boba"
    assert pets.sprite_geometry(installed / "spritesheet.png", json.loads((installed / "pet.json").read_text())) == (8, 11, 12, 13)


def test_local_zip_rejects_traversal_without_changing_selection(tmp_path: Path) -> None:
    home = tmp_path / "home"
    pets.initialize_store(home)
    archive = tmp_path / "unsafe.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.writestr("../pet.json", "{}")
        zf.writestr("spritesheet.png", png_bytes(96, 143))

    with pytest.raises(pets.PetError, match="unsafe archive"):
        pets.install_local(archive, home=home)

    assert pets.read_current(home) == "default"
    assert not (home / "codex-flow/pets/installed").exists()


def test_valid_zip_install_accepts_default_zip_file_metadata(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source")
    archive = tmp_path / "pet.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.write(source / "pet.json", "pet.json")
        zf.write(source / "spritesheet.png", "spritesheet.png")

    result = pets.install_local(archive, home=tmp_path / "home")

    assert result["id"] == "local-boba"


def test_nested_zip_package_keeps_manifest_relative_to_package_root(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source")
    archive = tmp_path / "nested.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.write(source / "pet.json", "boba/pet.json")
        zf.write(source / "spritesheet.png", "boba/spritesheet.png")

    result = pets.install_local(archive, home=tmp_path / "home")

    assert result["id"] == "local-boba"


def test_zip_with_explicit_directory_entries_can_be_installed(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source")
    archive = tmp_path / "folder.zip"
    with zipfile.ZipFile(archive, "w") as zf:
        zf.write(source, "boba/")
        zf.write(source / "pet.json", "boba/pet.json")
        zf.write(source / "spritesheet.png", "boba/spritesheet.png")
    assert pets.install_local(archive, home=tmp_path / "home")["id"] == "local-boba"


def test_large_atlas_is_rejected_before_replacing_selection(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source", image="webp")
    (source / "spritesheet.webp").write_bytes(webp_vpx_bytes(4608, 6864))
    with pytest.raises(pets.PetError, match="pixel"):
        pets.install_local(source, home=tmp_path / "home")
    assert pets.read_current(tmp_path / "home") == "default"


def test_corrupt_selection_does_not_break_listing(tmp_path: Path) -> None:
    home = tmp_path / "home"
    pets.install_local(write_pack(tmp_path / "source"), home=home)
    pets.pet_paths(home).current.write_bytes(b"\xff\xfe")
    assert pets.list_installed(home)[0]["current"] is False


def test_conflicting_local_id_is_rejected_without_replacing_original(tmp_path: Path) -> None:
    home = tmp_path / "home"
    first = write_pack(tmp_path / "one", display="One")
    second = write_pack(tmp_path / "two", display="Two")

    pets.install_local(first, home=home)
    original = (home / "codex-flow/pets/installed/local-boba/pet.json").read_bytes()
    with pytest.raises(pets.PetError, match="already installed"):
        pets.install_local(second, home=home)

    assert (home / "codex-flow/pets/installed/local-boba/pet.json").read_bytes() == original
    assert pets.read_current(home) == "local-boba"


def test_list_use_and_default_preserve_installed_resources(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    home = tmp_path / "home"
    pets.install_local(write_pack(tmp_path / "source"), home=home)

    assert [item["id"] for item in pets.list_installed(home)] == ["local-boba"]
    pets.use_pet("default", home=home)
    assert pets.read_current(home) == "default"
    assert (home / "codex-flow/pets/installed/local-boba/spritesheet.png").exists()

    assert pets.main(["--home", str(home), "list"]) == 0
    assert "local-boba" in capsys.readouterr().out


def test_compact_manifest_requires_trusted_asset_host_and_resolves_relative_entries() -> None:
    payload = {
        "v": 2,
        "assetBase": "https://assets.petdex.dev",
        "fields": ["slug", "displayName", "kind", "submittedBy", "spritesheet", "petJson", "zip", "spriteVersionNumber"],
        "pets": [["boba", "Boba", "creature", "author", "pets/boba/sprite.webp", "pets/boba/petjson.json", None, 1]],
    }
    entry = pets.parse_manifest(payload)[0]
    assert entry["slug"] == "boba"
    assert entry["spritesheetUrl"] == "https://assets.petdex.dev/pets/boba/sprite.webp"

    payload["assetBase"] = "https://evil.example"
    with pytest.raises(pets.PetError, match="untrusted asset host"):
        pets.parse_manifest(payload)


def test_exact_slug_wins_over_normalized_collision(monkeypatch: pytest.MonkeyPatch) -> None:
    entries = [{"slug": "a b", "displayName": "Wrong"}, {"slug": "a-b", "displayName": "Exact"}]
    monkeypatch.setattr(pets, "fetch_manifest", lambda: entries)
    assert pets._resolve_online("a-b")["displayName"] == "Exact"
    with pytest.raises(pets.PetError, match="ambiguous"):
        pets._resolve_online("A B")


def test_corrupt_zip_reports_resource_error_and_preserves_selection(tmp_path: Path) -> None:
    home = tmp_path / "home"
    source = write_pack(tmp_path / "source")
    pets.install_local(source, home=home)
    archive = tmp_path / "corrupt.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.write(source / "pet.json", "pet.json")
        zf.write(source / "spritesheet.png", "spritesheet.png")
    payload = bytearray(archive.read_bytes())
    metadata_start = payload.index((source / "pet.json").read_bytes())
    payload[metadata_start] ^= 1
    archive.write_bytes(payload)
    with pytest.raises(pets.PetError, match="archive"):
        pets.install_local(archive, home=home)
    assert pets.read_current(home) == "local-boba"


def test_store_readers_reject_symlinked_root(tmp_path: Path) -> None:
    home = tmp_path / "home"
    paths = pets.initialize_store(home)
    paths.root.rmdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "current").write_text("external")
    paths.root.symlink_to(outside, target_is_directory=True)
    assert pets.read_current(home) == "default"
    with pytest.raises(pets.PetError, match="symlink"):
        pets.list_installed(home)


@pytest.mark.parametrize("version", [True, False, 1.0, "1"])
def test_invalid_version_types_cannot_be_installed(tmp_path: Path, version: object) -> None:
    source = write_pack(tmp_path / "source", version=1)
    metadata = json.loads((source / "pet.json").read_text())
    metadata["spriteVersionNumber"] = version
    (source / "pet.json").write_text(json.dumps(metadata))
    with pytest.raises(pets.PetError, match="spriteVersionNumber"):
        pets.install_local(source, home=tmp_path / "home")


def test_download_failure_preserves_existing_selection(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    home = tmp_path / "home"
    pets.install_local(write_pack(tmp_path / "source"), home=home)
    old = pets.read_current(home)

    def failed_manifest(*_args, **_kwargs):
        raise pets.PetError("manifest unavailable")

    monkeypatch.setattr(pets, "fetch_manifest", failed_manifest)
    with pytest.raises(pets.PetError, match="manifest unavailable"):
        pets.install("boba", home=home)
    assert pets.read_current(home) == old


def test_online_install_retains_source_and_author(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    source = write_pack(tmp_path / "source")
    entry = {"slug": "boba", "submittedBy": "artist", "petJsonUrl": "https://assets.petdex.dev/boba/pet.json",
             "spritesheetUrl": "https://assets.petdex.dev/boba/sprite.png"}
    monkeypatch.setattr(pets, "_resolve_online", lambda _: entry)
    monkeypatch.setattr(pets, "download_bytes", lambda url, **_: (source / ("pet.json" if url.endswith(".json") else "spritesheet.png")).read_bytes())
    pets.install_online("boba", home=tmp_path / "home")
    provenance = json.loads((tmp_path / "home/codex-flow/pets/installed/boba/provenance.json").read_text())
    assert provenance["provider"] == "petdex"
    assert provenance["submittedBy"] == "artist"
    assert provenance["petJsonUrl"] == entry["petJsonUrl"]
    assert len(provenance["sha256"]) == 64


def test_webp_structural_geometry_accepts_v2_without_claiming_full_decode(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source", image="webp")

    result = pets.install_local(source, home=tmp_path / "home")

    assert result["id"] == "local-boba"
    assert pets.sprite_geometry(source / "spritesheet.webp", json.loads((source / "pet.json").read_text())) == (8, 11, 192, 208)


@pytest.mark.parametrize("version, expected", [(1, (8, 9, 12, 13)), (2, (8, 11, 12, 13))])
def test_png_v1_and_v2_geometry_uses_metadata_version(tmp_path: Path, version: int, expected: tuple[int, int, int, int]) -> None:
    source = write_pack(tmp_path / f"source-{version}", version=version)

    assert pets.sprite_geometry(source / "spritesheet.png", json.loads((source / "pet.json").read_text())) == expected


def test_truncated_image_payload_is_rejected_before_staging(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source")
    image = source / "spritesheet.png"
    image.write_bytes(image.read_bytes()[:-1])

    with pytest.raises(pets.PetError, match="truncated|incomplete"):
        pets.install_local(source, home=tmp_path / "home")


def test_webp_header_without_frame_is_rejected(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source", image="webp")
    payload = (source / "spritesheet.webp").read_bytes()
    header_only = payload[12:30]
    source.joinpath("spritesheet.webp").write_bytes(b"RIFF" + struct.pack("<I", 4 + len(header_only)) + b"WEBP" + header_only)

    with pytest.raises(pets.PetError, match="truncated|no complete image frame"):
        pets.install_local(source, home=tmp_path / "home")


def test_extension_and_static_image_format_must_match(tmp_path: Path) -> None:
    source = write_pack(tmp_path / "source", image="png")
    source.joinpath("spritesheet.png").write_bytes(webp_vpx_bytes(1536, 2288))

    with pytest.raises(pets.PetError, match="format|PNG"):
        pets.install_local(source, home=tmp_path / "home")


def test_overlay_rejected_activation_is_distinguished_and_selection_remains_saved(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    home = tmp_path / "home"
    source = write_pack(tmp_path / "source")
    pets.initialize_store(home)
    sock_path = Path("/tmp/codex-flow-pet-test.sock")
    sock_path.unlink(missing_ok=True)
    monkeypatch.setattr(pets, "overlay_socket_path", lambda _home: sock_path)
    received: list[str] = []

    import socket
    sock_path.parent.mkdir(parents=True, exist_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(sock_path))
    server.listen(1)

    def serve() -> None:
        conn, _ = server.accept()
        with conn:
            received.append(conn.recv(4096).decode())
            conn.sendall(b'{"ok": false, "error": "decode rejected"}\n')
        server.close()

    thread = threading.Thread(target=serve)
    thread.start()
    result = pets.install_local(source, home=home)
    thread.join(timeout=2)

    assert result["activation"] == "rejected"
    assert pets.read_current(home) == "local-boba"
    assert received == ["pet reload\n"]


def test_selection_file_directory_is_rejected_without_raw_os_error(tmp_path: Path) -> None:
    home = tmp_path / "home"
    paths = pets.initialize_store(home)
    paths.current.mkdir()

    with pytest.raises(pets.PetError, match="managed path"):
        pets.use_pet("default", home=home)
