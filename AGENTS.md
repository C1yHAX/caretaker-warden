# Release packaging preference

The user requires version 1.0.0 for the current first releases. Release download
ZIPs must contain only files required to run the mod, under the installation
folder structure. Keep this policy for future packaging changes.

- Do not include README, BUILDING, THIRD-PARTY-NOTICES, CHANGELOG, release notes,
  license text files, source images, development tools, installers, verification
  reports or file manifests in the mod ZIP. Keep them in the repository and on
  the project/release pages instead.
- Preserve required runtime files such as enabled.txt, mods.txt, load_order.txt,
  .tlcaddon.json registrations, Lua scripts, DLLs and runtime configuration.
- Use tools/package_release.py. Verify the complete ZIP member list and runtime
  file hashes before publishing. Checksums may be separate release attachments.
- Apply the same runtime-only rule to the complete local modpack ZIP. Preserve
  local settings and saved state; do not publish personal files in standalone mods.
- Do not start the game automatically for packaging or offline verification.
- Include the neutral `config/settings.ini` template as `Warden/settings.ini` in
  releases. Never package a local or installed user's settings file.
- Verify a clean extraction of the actual ZIP with `tools/test_release_package.py`;
  creating a settings file in a test before startup is not a fresh-install check.
