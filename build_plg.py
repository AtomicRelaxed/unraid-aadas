#!/usr/bin/env python3
"""Build aadas.plg from the sources (all files inline). Usage: build_plg.py <version>"""
import sys, os, base64
D = os.path.dirname(os.path.abspath(__file__)); P = D + "/src/plugin/aadas"; ver = sys.argv[1]
rd = lambda p: open(p).read()
files = [("/usr/local/emhttp/plugins/aadas/AADAS.page", rd(P + "/AADAS.page"), None),
         ("/usr/local/emhttp/plugins/aadas/README.md", rd(P + "/README.md"), None),
         ("/usr/local/emhttp/plugins/aadas/include/action.php", rd(P + "/include/action.php"), None),
         ("/usr/local/emhttp/plugins/aadas/event/driver_loaded", rd(P + "/event/driver_loaded"), "0755"),
         ("/usr/local/emhttp/plugins/aadas/event/stopped", rd(P + "/event/stopped"), "0755"),
         ("/usr/local/emhttp/plugins/aadas/event/started", rd(P + "/event/started"), "0755"),
         ("/usr/local/emhttp/plugins/aadas/scripts/aadas.sh", rd(D + "/src/aadas.sh"), "0755")]
for _, c, _m in files: assert "]]>" not in c
o = ['<?xml version="1.0" standalone="yes"?>', '<!DOCTYPE PLUGIN [', '<!ENTITY name "aadas">', '<!ENTITY author "RaisonRed">',
     f'<!ENTITY version "{ver}">', '<!ENTITY launch "Utilities/AADAS">', '<!ENTITY gitURL "https://raw.githubusercontent.com/RaisonRed/unraid-aadas/main">', '<!ENTITY pluginURL "&gitURL;/aadas.plg">', ']>',
     '<PLUGIN name="&name;" author="&author;" version="&version;" launch="&launch;" icon="aadas.png" pluginURL="&pluginURL;" support="https://github.com/RaisonRed/unraid-aadas/issues" min="7.0.0">', '<CHANGES>', rd(D + "/CHANGES.md").strip(), '</CHANGES>',
     '<!-- License: GPLv3 or later -->']
for path, c, mode in files:
    m = f' Mode="{mode}"' if mode else ''
    o.append(f'<FILE Name="{path}"{m}>\n<INLINE><![CDATA[\n{c}]]></INLINE>\n</FILE>')
icon = base64.b64encode(open(P + "/images/aadas.png", "rb").read()).decode()
o.append(f'''<FILE Run="/bin/bash">
<INLINE><![CDATA[
mkdir -p /usr/local/emhttp/plugins/aadas/images
echo '{icon}' | base64 -d > /usr/local/emhttp/plugins/aadas/images/aadas.png
]]></INLINE>
</FILE>''')
o.append(r'''<FILE Run="/bin/bash">
<INLINE><![CDATA[
mkdir -p /boot/config/aadas/profiles /boot/config/aadas/backups /boot/config/plugins/aadas
cp -f /usr/local/emhttp/plugins/aadas/scripts/aadas.sh /boot/config/aadas/aadas.sh   # boot step needs it on the flash (runs before plugins load)
[ -f /boot/config/aadas/global.cfg ] || printf 'GLOBAL_POOLS=""\nAUTO_DETECT="no"\nAUTOSAVE="off"\nSAVE_ON_STOP="yes"\nIGNORE_IDS=""\n' > /boot/config/aadas/global.cfg
if ! grep -q 'aadas.sh boot' /boot/config/go; then
  cp -p /boot/config/go /boot/config/go.bak_aadas
  sed -i 's|^/usr/local/sbin/emhttp|timeout 60 bash /boot/config/aadas/aadas.sh boot \|\| true\n/usr/local/sbin/emhttp|' /boot/config/go
  echo "Added the boot step to /boot/config/go (backup: go.bak_aadas)."
fi
A=$(grep -oP '^AUTOSAVE="\K\w+' /boot/config/aadas/global.cfg 2>/dev/null)
if [ -n "$A" ] && [ "$A" != off ]; then bash /boot/config/aadas/aadas.sh schedule "$A" >/dev/null; fi   # restore schedule after reinstall
echo "AADAS installed. Set GLOBAL_POOLS in /boot/config/aadas/global.cfg (pools that are never swapped)."
]]></INLINE>
</FILE>
<FILE Run="/bin/bash" Method="remove">
<INLINE><![CDATA[
sed -i '/aadas.sh boot/d' /boot/config/go
rm -f /boot/config/plugins/aadas/aadas.cron; if [ -x /usr/local/sbin/update_cron ]; then /usr/local/sbin/update_cron; fi
rm -rf /usr/local/emhttp/plugins/aadas
echo "AADAS removed. Saved sets in /boot/config/aadas are kept."
]]></INLINE>
</FILE>
</PLUGIN>''')
open(D + "/aadas.plg", "w").write("\n".join(o) + "\n")
print("built", ver)
