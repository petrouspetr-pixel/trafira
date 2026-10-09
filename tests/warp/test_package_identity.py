import json
import os
import subprocess
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
    @unittest.skipIf(os.name == 'nt', 'OpenWrt shell lifecycle requires Linux')
    def test_init_install_is_inert(self):
        init=ROOT/'components/warp/luci-app-trafira-warp/root/etc/init.d/trafira-warp'
        self.assertFalse(Path('/etc/trafira-warp/transport.json').exists())
        self.assertFalse(Path('/etc/trafira/warp-packages/journal.json').exists())
        for upgrade in ['0','1']:
            result=subprocess.run(['sh','-c','. "$1"; start_service','sh',str(init)],env={**os.environ,'PKG_UPGRADE':upgrade},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,'')
if __name__=='__main__': unittest.main()
