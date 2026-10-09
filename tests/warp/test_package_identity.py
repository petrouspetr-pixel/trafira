import json
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
class PackageIdentity(unittest.TestCase):
    def test_optional_packages_and_sources(self):
        base=ROOT/'components/warp'
        manifest=json.loads((base/'UPSTREAM.json').read_text())
        self.assertEqual(manifest['integration']['commit'],'72cfeef7f1838ad991ed6242188621df2691e86a')
        for name in ['luci-app-trafira-warp','trafira-warp-awg','trafira-warp-scout']:
            text=(base/name/'Makefile').read_text()
            self.assertIn(name,text)
            self.assertTrue((base/name/'LICENSE').is_file())
        self.assertNotIn('+luci-app-trafira-warp',(ROOT/'trafira/Makefile').read_text())
    def test_inert_install(self):
        base=ROOT/'components/warp/luci-app-trafira-warp'
        config=(base/'root/etc/config/trafira-warp').read_text()
        self.assertIn("option enabled '0'",config)
        self.assertNotIn('postinst', (base/'Makefile').read_text())
        for path in (base/'root').rglob('*'):
            self.assertNotEqual(path.name,'uci-defaults')
if __name__=='__main__': unittest.main()
