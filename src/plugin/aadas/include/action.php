<?php
/* AADAS - action endpoint. GPLv3 or later.
 * CSRF is validated by Unraid's local_prepend.php for every POST. */
header('Content-Type: text/plain; charset=utf-8');
$cmd  = $_POST['cmd']  ?? '';
$name = $_POST['name'] ?? '';
$name2 = $_POST['name2'] ?? '';
$ok = '/^[A-Za-z0-9_-]{1,32}$/';
if (!in_array($cmd, ['save', 'switch', 'rename', 'delete', 'schedule', 'set'], true)) { http_response_code(400); exit("invalid command\n"); }
if ($cmd === 'schedule') { if (!in_array($name, ['off', 'daily', 'weekly'], true)) { http_response_code(400); exit("invalid schedule\n"); } }
elseif ($cmd === 'set') { if (!in_array($name, ['detect', 'save_on_stop'], true) || !in_array($name2, ['yes', 'no'], true)) { http_response_code(400); exit("invalid setting\n"); } }
elseif (!preg_match($ok, $name)) { http_response_code(400); exit("invalid set name\n"); }
$two = ($cmd === 'rename') || ($cmd === 'set') || ($cmd === 'switch' && $name === 'new');
if ($two && $cmd !== 'set' && !preg_match($ok, $name2)) { http_response_code(400); exit("invalid new name\n"); }
$args = escapeshellarg($cmd).' '.escapeshellarg($name).($two ? ' '.escapeshellarg($name2) : '');
$out = shell_exec('bash /boot/config/aadas/aadas.sh '.$args.' 2>&1');
echo $out ?: "(no output)\n";
