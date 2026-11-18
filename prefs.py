"""ProfitView: prepare the Chromium profile before every start (called from /etc/chromium.d/profitview).

- marks the last session as cleanly exited: a container stop/update kills Chromium, which would otherwise show the
  blocking "Restore pages?" bubble instead of opening the startup pages from the policy (RestoreOnStartupURLs)
- enables developer mode: without it Chromium 156+ disables the unpacked extension as soon as it reloads
- pins the extension's action icon, only when the profile is new (so the user can still unpin it)
- drops the cached service worker scripts when the extension files changed (update or dev deploy): Chromium keeps
  running the cached background code after a restart, even with a new manifest version (tested with Chromium 156)
"""
import hashlib, json, os, shutil

EXT_ID = 'gmflieilmcgbdepadibceklnjbjimpof'
EXT_DIR = '/opt/profitview/ext'
profile_dir = os.path.expanduser('~/.config/chromium')
path = profile_dir + '/Default/Preferences'

md5 = hashlib.md5()
for root, dirs, files in sorted(os.walk(EXT_DIR)):
	dirs.sort()
	for name in sorted(files):
		md5.update(os.path.join(root, name).encode())
		with open(os.path.join(root, name), 'rb') as f:
			md5.update(f.read())
stamp_file = profile_dir + '/profitview-ext.md5'
stamp = open(stamp_file).read() if os.path.exists(stamp_file) else ''
if stamp != md5.hexdigest():
	# other sites' service workers (e.g. TradingView) are simply registered again on their next visit
	shutil.rmtree(profile_dir + '/Default/Service Worker', ignore_errors=True)
	os.makedirs(profile_dir, exist_ok=True)
	with open(stamp_file, 'w') as f:
		f.write(md5.hexdigest())

try:
	with open(path, encoding='utf-8') as f:
		prefs = json.load(f)
except FileNotFoundError:
	prefs = {'extensions': {'pinned_extensions': [EXT_ID]}}
except ValueError:
	raise SystemExit(f'prefs.py: {path} is not valid JSON, left unchanged')

profile = prefs.setdefault('profile', {})
profile['exit_type'] = 'Normal'
profile['exited_cleanly'] = True
prefs.setdefault('extensions', {}).setdefault('ui', {})['developer_mode'] = True

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + '.tmp', 'w', encoding='utf-8') as f:
	json.dump(prefs, f)
os.replace(path + '.tmp', path)
