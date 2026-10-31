"""Exercise the extracted public ZIP, including config I/O and missing-file failures.

No game is started. Set WARDEN_UE4SS_ZIP to the official prerequisite ZIP to use its
real UEHelpers module; otherwise the normal engine stand-in supplies that boundary.
"""
from pathlib import Path
import ctypes
import hashlib
import json
import os
import tempfile
import unittest
import zipfile
from lupa.lua54 import LuaRuntime
import package_release as package

ROOT = Path(__file__).resolve().parent.parent
MOCK_SOURCE = (ROOT / 'tools/mock/ue4ss_mock.lua').read_text(encoding='utf-8')


class ReleasePackage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # May point to a re-downloaded public asset for exactly the same checks.
        cls.archive = Path(os.environ.get('WARDEN_RELEASE_ZIP', ROOT / 'dist' / package.ARCHIVE))
        with zipfile.ZipFile(cls.archive) as archive:
            cls.files = {name: archive.read(name) for name in archive.namelist()}
        cls.ue4ss = os.environ.get('WARDEN_UE4SS_ZIP')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='warden-clean-install-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.mod = self.root / package.PREFIX
        with zipfile.ZipFile(self.archive) as archive:
            archive.extractall(self.root)
        self.config = self.mod / 'settings.ini'

    def runtime(self, deny_settings_read=False):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().mock = lua.execute(MOCK_SOURCE)
        scripts = self.mod / 'Scripts'
        shared = self.mod.parent / 'shared'
        lua.globals().releaseRoot = self.root.as_posix().lower()
        lua.globals().denySettingsRead = deny_settings_read
        lua.globals().runtimePath = scripts.as_posix() + '/?.lua;' + shared.as_posix() + '/?/?.lua'
        lua.execute('''
            package.path=runtimePath;package.cpath=''
            local originalOpen=io.open
            io.open=function(path,mode)
                local clean=path:gsub('\\\\','/'):lower()
                assert(clean:sub(1,#releaseRoot+1)==releaseRoot..'/', 'I/O outside extracted release: '..path)
                if denySettingsRead and mode=='r' and clean:match('/settings%.ini$') then
                    return nil,'Permission denied',13
                end
                return originalOpen(path,mode)
            end
            local mockLoad=package.loadlib
            package.loadlib=function(path,symbol)
                local file,err=io.open(path,'rb');assert(file,err);file:close()
                return mockLoad(path,symbol)
            end
        ''')
        if self.ue4ss:
            with zipfile.ZipFile(self.ue4ss) as archive:
                name = 'ue4ss/Mods/shared/UEHelpers/UEHelpers.lua'
                target = shared / 'UEHelpers/UEHelpers.lua'
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
            lua.execute('''
                local pc=package.preload.UEHelpers().GetPlayerController()
                package.preload.UEHelpers=nil
                CreateInvalidObject=function() return {IsValid=function() return false end} end
                local originalFind=FindAllOf
                FindAllOf=function(class)
                    if class=='PlayerController' then return {pc} end
                    return originalFind(class)
                end
            ''')
        lua.execute('require("main")')
        self.lua = lua
        return lua

    def open_all_pages(self, lua, key='F1'):
        lua.globals().expectedKey = key
        lua.execute('''
            assert(mock.keybinds[1].key==expectedKey)
            mock.keybinds[1].fn();mock.timers[50]()
            local ui=require('ui')
            assert(ui.isOpen and #ui.pages==9)
            for i=1,#ui.pages do ui.selectPage(i);ui.tick() end
            mock.keybinds[1].fn();mock.timers[50]();assert(not ui.isOpen)
            mock.keybinds[1].fn();mock.timers[50]();assert(ui.isOpen)
            for _,line in ipairs(mock.log) do assert(not line:find('ERROR',1,true),line) end
            assert(#mock.forbidden==0)
        ''')

    def test_public_archive_has_complete_manifest_and_default_config(self):
        package.verify_dependencies(self.files)
        rows = json.loads((ROOT / 'Dateien.json').read_text(encoding='utf-8'))
        self.assertEqual(set(self.files), {row['path'] for row in rows})
        for row in rows:
            data = self.files[row['path']]
            self.assertEqual(len(data), row['bytes'])
            self.assertEqual(hashlib.sha256(data).hexdigest(), row['sha256'])
        self.assertEqual(package.config_values(self.config.read_bytes()), package.DEFAULTS)
        self.assertFalse(any(n.endswith(('.tsv', '.md', '.py')) for n in self.files))

    def test_untouched_zip_starts_and_reopens_with_all_defaults(self):
        before = self.config.read_bytes()
        lua = self.runtime()
        self.assertEqual(dict(lua.eval('require("core").settings').items()), package.DEFAULTS)
        self.open_all_pages(lua)
        self.assertEqual(self.config.read_bytes(), before)

    def test_missing_config_is_created_at_start_without_clicking_a_setting(self):
        self.config.unlink()
        lua = self.runtime()
        self.assertEqual(package.config_values(self.config.read_bytes()), package.DEFAULTS)
        self.open_all_pages(lua)

    def test_existing_english_config_and_saved_locations_survive_start_and_save(self):
        data = b'; custom settings\nlanguage = en\ntoggleKey = F2\nposition = right\nwalk = false\ncustomValue = keep-me\n'
        self.config.write_bytes(data)
        personal = self.mod / 'hotspots.tsv'
        personal.write_text('My own location\t1\t2\t3\t0\n', encoding='utf-8')
        before = personal.read_bytes()
        lua = self.runtime()
        self.assertEqual(self.config.read_bytes(), data)
        self.assertEqual(lua.eval('require("i18n").getLanguage()'), 'en')
        self.open_all_pages(lua, 'F2')
        lua.execute('require("core").setSetting("block",false)')
        values = package.config_values(self.config.read_bytes())
        self.assertEqual(values['language'], 'en')
        self.assertEqual(values['toggleKey'], 'F2')
        self.assertEqual(values['customValue'], 'keep-me')
        self.assertEqual(values['walk'], 'false')
        self.assertEqual(values['block'], 'false')
        self.assertEqual(personal.read_bytes(), before)

    def test_utf8_bom_does_not_hide_english_selection(self):
        self.config.write_bytes(b'\xef\xbb\xbflanguage = en\n')
        lua = self.runtime()
        self.assertEqual(lua.eval('require("i18n").getLanguage()'), 'en')
        self.open_all_pages(lua)

    def test_unreadable_existing_config_is_not_overwritten_as_missing(self):
        before = b'; existing settings must survive\nlanguage = en\n'
        self.config.write_bytes(before)
        lua = self.runtime(deny_settings_read=True)
        self.open_all_pages(lua)
        self.assertEqual(self.config.read_bytes(), before)

    def test_package_rejects_missing_ini_dll_and_lua_dependency(self):
        for suffix in ['settings.ini', 'Scripts/native/warden_crafting.dll', 'Scripts/features/strength.lua']:
            with self.subTest(suffix=suffix):
                broken = dict(self.files)
                del broken[package.PREFIX + suffix]
                with self.assertRaises(AssertionError):
                    package.verify_dependencies(broken)

    def test_personal_config_is_rejected_by_release_validator(self):
        broken = dict(self.files)
        broken[package.PREFIX + 'settings.ini'] = b'language = en\nposition = right\n'
        with self.assertRaises(AssertionError):
            package.verify_dependencies(broken)

    @unittest.skipUnless(os.name == 'nt', 'Windows native loader check')
    def test_packaged_native_dll_loads_and_exports_the_required_entrypoints(self):
        # DllMain does no work; resolving exports does not enable any game hook.
        library = ctypes.WinDLL(str(self.mod / 'Scripts/native/warden_crafting.dll'))
        try:
            for name in ('enable', 'disable', 'status'):
                self.assertTrue(getattr(library, 'warden_crafting_' + name))
        finally:
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.FreeLibrary.argtypes = [ctypes.c_void_p]
            kernel.FreeLibrary.restype = ctypes.c_int
            self.assertTrue(kernel.FreeLibrary(library._handle))


if __name__ == '__main__':
    unittest.main()
