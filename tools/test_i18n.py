"""Both menu languages use real Lua modules; tests never start the game."""
from pathlib import Path
import re
import unittest
from lupa.lua54 import LuaRuntime
import test_movement_packages as fixtures

ROOT=Path(__file__).resolve().parent.parent
SCRIPTS=ROOT/'Warden/Scripts'


class Localization(unittest.TestCase):
    def runtime(self,language='de'):
        lua=LuaRuntime(unpack_returned_tuples=True)
        lua.execute(f'package.path="{SCRIPTS.as_posix()}/?.lua;{ROOT.as_posix()}/tools/mock/?.lua;"..package.path')
        lua.execute('mock=require("ue4ss_mock"); core=require("core")')
        lua.globals().chosenLanguage=language
        lua.execute(r'''
          core.readLines=function(name)
            if name=='settings.ini' then return {'language = '..chosenLanguage,'position = right','walk = false','toggleKey = F2'} end
            return {}
          end
          writes={};core.writeLines=function(name,lines) writes[name]=lines;return true end
          shown={}
          mock.RETURNS.SetText=function(_,value) shown[#shown+1]=value:ToString() end
          mock.RETURNS.SetHintText=function(_,value) shown[#shown+1]=value:ToString() end
          require('main');mock.keybinds[1].fn();mock.timers[50]()
          ui=require('ui');assert(ui.isOpen)
          for i=1,#ui.pages do ui.selectPage(i);ui.tick() end
        ''')
        return lua

    def test_english_config_applies_before_feature_modules_and_all_nine_pages(self):
        lua=self.runtime('en')
        lua.execute(r'''
          assert(#ui.pages==9 and require('i18n').getLanguage()=='en')
          assert(core.setting('position')=='right' and core.setting('walk',true)==false)
          assert(core.setting('toggleKey')=='F2')
          local text=table.concat(shown,'\n')
          for _,expected in ipairs({'PLAYER','WEAPONS','UNLOCKS','SPAWN','TELEPORT','BOAT','WORLD','SYSTEM','LOG',
            'God mode','Flight speed','Unlimited inventory weight','All components',
            'Outfit boat','Charge batteries','Free Crafting without materials','Language'}) do
            assert(text:find(expected,1,true),expected)
          end
          for _,forbidden in ipairs({'Spieler','Überleben','Bauteile','Batterien','Menü','Schalter','Fensterposition'}) do
            assert(not text:find(forbidden,1,true),forbidden)
          end
          assert(require('features.packages').status()=='Ready')
          local crafting=require('features.crafting')
          assert(not crafting.status().message:find('Herstellungsmodul',1,true))
          crafting.setEnabled(false);assert(crafting.status().message=='Off')
        ''')

    def test_german_config_preserves_existing_labels_and_status(self):
        lua=self.runtime('de')
        lua.execute(r'''
          local text=table.concat(shown,'\n')
          assert(text:find('SPIELER',1,true) and text:find('Gottmodus',1,true))
          assert(text:find('Alle Bauteile',1,true) and text:find('Boot ausruesten',1,true))
          assert(require('features.packages').status()=='Bereit')
        ''')

    def test_all_translated_templates_preserve_format_and_spacing(self):
        lua=self.runtime()
        table=lua.eval('require("locales.en")')
        self.assertGreaterEqual(len(list(table)),550)
        fmt=re.compile(r'%(?:[-+ #0]*\d*(?:\.\d+)?[a-zA-Z%])')
        for source,target in table.items():
            self.assertTrue(target,source)
            self.assertEqual(fmt.findall(source),fmt.findall(target),(source,target))
            self.assertEqual(source.startswith(' '),target.startswith(' '),(source,target))
            self.assertEqual(source.endswith(' '),target.endswith(' '),(source,target))

    def test_every_translation_call_has_a_dictionary_entry(self):
        lua=self.runtime();dictionary=lua.eval('require("locales.en")')
        for path in SCRIPTS.rglob('*.lua'):
            if path.parent.name=='locales':continue
            for literal in re.findall(r'\btr\(("(?:\\.|[^"\\])*")\)',path.read_text(encoding='utf8')):
                source=lua.eval(literal)
                self.assertIsNotNone(dictionary[source],f'{path.name}: {source}')

    def test_no_unwrapped_known_german_text_in_runtime_code(self):
        lua=self.runtime();dictionary=lua.eval('require("locales.en")')
        token=re.compile(r'--\[\[.*?\]\]|--[^\n]*|(?P<s>"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')',re.S)
        for path in SCRIPTS.rglob('*.lua'):
            if path.parent.name in ('locales','data') or path.name=='item_names.lua':continue
            source=path.read_text(encoding='utf8')
            for match in token.finditer(source):
                if not match.group('s'):continue
                value=lua.eval(match.group())
                if dictionary[value] is not None:
                    self.assertTrue(source[:match.start()].endswith('tr('),f'{path.name}: {value}')

    def test_settings_roundtrip_keeps_language_and_other_options(self):
        lua=self.runtime('EN-us')
        lua.execute(r'''
          assert(require('i18n').getLanguage()=='en')
          core.setSetting('block',true)
          local saved=table.concat(writes['settings.ini'],'\n')
          for _,line in ipairs({'language = en','walk = false','position = right','toggleKey = F2','block = true'}) do
            assert(saved:find(line,1,true),line)
          end
          core.readLines=function() return writes['settings.ini'] end
          core.loadSettings();assert(require('i18n').getLanguage()=='en')
        ''')

    def test_missing_invalid_and_regional_language_fallbacks(self):
        lua=self.runtime()
        lua.execute(r'''
          local i=require('i18n')
          assert(i.normalize(nil)=='de' and i.normalize('fr')=='de')
          assert(i.normalize(' DE-de ')=='de' and i.normalize('EN_GB')=='en')
          core.readLines=function() return {'walk = false'} end
          core.loadSettings();assert(i.getLanguage()=='de' and core.setting('walk',true)==false)
          i.setLanguage('en')
          assert(i.t('Boot')=='Boat' and i.t('My custom place')=='My custom place')
          assert(i.t('/Game/Boot.Boot')=='/Game/Boot.Boot')
          assert(core.thousands(12345)=='12,345' and core.thousands(100000)=='100,000')
          i.setLanguage('de');assert(core.thousands(12345)=='12.345')
        ''')

    def test_material_fallback_and_bilingual_search_without_game_culture_change(self):
        fixtures.Features.setUp(self)
        self.lua.execute(r'''
          local i=require('i18n');i.setLanguage('en')
          local n=require('item_names')
          local path='/Game/Data/Assets/Materials/DA_Material_Fabric.DA_Material_Fabric'
          local name,search=n.describe(nil,path)
          assert(name=='Fabric' and n.matches({search=search},'stoff'))
          assert(n.matches({search=search},'fabric'))
          local custom=n.describe('Mein Mod-Stoff','/MyMod/Fabric.Fabric')
          assert(custom=='Mein Mod-Stoff') -- game/mod-owned names are not rewritten
          i.setLanguage('de');assert(n.describe(nil,path)=='Stoff')
        ''')

    def test_english_packages_deliver_same_items_and_report_english_results(self):
        fixtures.Features.setUp(self)
        self.lua.execute(r'''
          require('i18n').setLanguage('en')
          a=item('/Game/A.A',19,true);package.loaded['data.item_paths']={a.path}
          p=require('features.packages');p.start('parts',50);finish(p)
          assert(inventoryCounts[a.path]==50)
          assert(p.status()=='1 / 1 types, 50 items; 0 incomplete, 0 unsuccessful')
          assert(table.concat(logs,'\n'):find('Catalog:',1,true))
        ''')


if __name__=='__main__':unittest.main()
