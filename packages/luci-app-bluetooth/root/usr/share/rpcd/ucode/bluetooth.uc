#!/usr/bin/env ucode

'use strict';

import { popen } from 'fs';

const BTCTL = '/usr/bin/bluetoothctl';
// Every bluetoothctl call is bounded: the interactive shell hangs until BlueZ
// times out otherwise, which would hang the RPC call and the LuCI page with it.
const BTCTL_TIMEOUT = 'timeout 20';

const shellquote = (s) => {
	return `'${replace(s, "'", "'\\''")}'`;
};

// bluetoothctl errors on stderr and exits non-zero; merge both so the caller
// can tell success from failure.
const run_btctl = (command) => {
	try {
		const handle = popen(`${BTCTL_TIMEOUT} ${BTCTL} ${command} 2>&1`, 'r');
		if (!handle)
			return null;

		const output = handle.read('all');
		handle.close();

		return output;
	}
	catch (e) {
		return null;
	}
};

// bluetoothctl prints nothing on success and something like
// "Error: Connection failed: ..." or "Failed to set powered" on failure.
const bt_ok = (output) => {
	if (output == null)
		return false;

	if (match(output, /error|failed|denied|not permitted|invalid/i))
		return false;

	return true;
};

// Outcomes that mean BlueZ is already in the state we asked for.  Turning off a
// scan that is not running, disconnecting or removing a device that is not
// connected are all harmless, so those commands may answer with one of these.
const ALREADY = /not found|not supported|not connected|not paired|not bonded|not registered|already/i;

const bt_relaxed = (output) => {
	if (bt_ok(output) || (output != null && match(output, ALREADY)))
		return true;

	return false;
};

// bluetoothctl emits colour codes plus a flood of [CHG]/[NEW] events; keep only
// readable text and the last line, which is where the verdict lands.
const bt_msg = (output) => {
	if (output == null)
		return '';

	let last = '';
	const lines = split(replace(output, /\x1b\[[0-9;]*m/g, ''), '\n');
	for (let i = 0; i < length(lines); i++) {
		const t = trim(lines[i]);
		if (length(t) > 0 && !match(t, /^\[(CHG|NEW)\]/))
			last = t;
	}

	return last;
};

const is_on = (v) => (v === true || v === 1 || v === '1' || v === 'true' || v === 'on');

const valid_mac = (mac) => {
	return (type(mac) == 'string' && match(trim(mac), /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/));
};

// Read a uci value; ufivoice may not be installed, in which case this yields ''.
const uci_get = (key) => {
	try {
		const handle = popen(`uci -q get ${shellquote(key)}`, 'r');
		if (!handle)
			return '';

		const out = handle.read('all');
		handle.close();

		return trim(out);
	}
	catch (e) {
		return '';
	}
};

// True when a process by this exact name is running.  pgrep -x is unreliable
// on this platform and plain pgrep misses processes whose comm differs from
// their script (python3 -u /usr/sbin/ufi-voiced).  Match the full command line
// with the first character bracketed, so the shell wrapper that runs this very
// pgrep does not match itself.
const running = (name) => {
	const n = `${name}`;
	const pat = length(n) > 0 ? ('[' + substr(n, 0, 1) + ']' + substr(n, 1)) : n;

	try {
		const handle = popen(`pgrep -f ${shellquote(pat)} >/dev/null 2>&1 && echo 1 || echo 0`, 'r');
		if (!handle)
			return false;

		const out = trim(handle.read('all'));
		handle.close();

		return out === '1';
	}
	catch (e) {
		return false;
	}
};

// The WCNSS controller on this platform exposes Handsfree Audio Gateway only:
// call audio goes hfp-ag -> SCO -> modem DSP, with no A2DP and no bluealsa.  The
// frontend then shows the call headset instead of A2DP codec/volume controls.
// If a build ever ships bluealsa, capability flips to 'a2dp' automatically.
const audio_capability = () => {
	try {
		const handle = popen('command -v bluealsa >/dev/null 2>&1 && echo a2dp || echo hfp', 'r');
		if (!handle)
			return 'hfp';

		const out = trim(handle.read('all'));
		handle.close();

		return out === 'a2dp' ? 'a2dp' : 'hfp';
	}
	catch (e) {
		return 'hfp';
	}
};

const methods = {
	get_status: {
		call: function() {
			// The Bluetooth audio reality on this platform (see audio_capability).
			const audio = {
				capability: audio_capability(),
				hfp_ag: running('hfp-ag'),
				ufivoiced: running('ufi-voiced'),
				headset_mac: uci_get('ufivoice.main.bt_headset')
			};

			const output = run_btctl('show');
			if (!output) {
				return {
					controller: 'Unknown',
					powered: false,
					name: 'Unknown',
					alias: 'Unknown',
					discoverable: false,
					pairable: false,
					discovering: false,
					audio: audio
				};
			}

			const parse_value = (regex) => {
				const m = match(output, regex);
				return m ? trim(m[1]) : null;
			};

			const parse_bool = (regex) => {
				const val = parse_value(regex);
				return val === 'yes';
			};

			return {
				controller: parse_value(/Controller\s+([0-9A-F:]+)/) || 'Unknown',
				powered: parse_bool(/Powered:\s*([a-z]+)/),
				name: parse_value(/Name:\s*([^\n]+)/) || 'Unknown',
				alias: parse_value(/Alias:\s*([^\n]+)/) || 'Unknown',
				discoverable: parse_bool(/Discoverable:\s*([a-z]+)/),
				pairable: parse_bool(/Pairable:\s*([a-z]+)/),
				discovering: parse_bool(/Discovering:\s*([a-z]+)/),
				audio: audio
			};
		}
	},

	get_devices: {
		call: function() {
			try {
				const handle = popen('/usr/libexec/bluetooth/bt_device.sh', 'r');
				if (!handle) {
					return { devices: [] };
				}

				const output = handle.read('all');
				handle.close();

				if (!output) {
					return { devices: [] };
				}

				try {
					const result = json(output);

					if (result && result.devices) {
						return result;
					} else {
						return { devices: [] };
					}
				} catch (e) {
					return { devices: [], error: 'Failed to parse device list.' };
				}
			}
			catch (e) {
				return { devices: [] };
			}
		}
	},

	set_power: {
		args: { on: 0 },
		call: function(req) {
			const cmd = is_on(req.args.on) ? 'power on' : 'power off';
			const output = run_btctl(cmd);

			if (!bt_ok(output))
				return { success: false, error: 'Setting powered failed.' };

			return { success: true };
		}
	},

	// Peripheral role: a phone pairs *to* this router, so it has to be
	// discoverable first.  BlueZ stops advertising again once
	// DiscoverableTimeout elapses, which is why a bounded duration is offered
	// instead of a bare on/off -- and why this used to be missing entirely:
	// nothing on the device ever set discoverable, so no phone could ever find
	// the router.
	//
	// bluetoothctl's --timeout is a *command* timeout, not an advertising
	// duration, so the duration has to be programmed with
	// "discoverable-timeout" first.
	set_discoverable: {
		args: { on: 0, seconds: 180 },
		call: function(req) {
			if (is_on(req.args.on)) {
				let sec = `${req.args.seconds}`;
				if (!match(sec, /^[0-9]+$/) || +sec < 10 || +sec > 7200)
					sec = '180';

				if (!bt_ok(run_btctl(`-- discoverable-timeout ${sec}`)))
					return { success: false, error: 'Setting the discoverable timeout failed.' };

				const output = run_btctl('discoverable on');

				if (!bt_ok(output))
					return { success: false, error: 'Setting discoverable failed.' };

				return { success: true };
			}

			const output = run_btctl('discoverable off');

			if (!bt_ok(output))
				return { success: false, error: 'Setting discoverable failed.' };

			return { success: true };
		}
	},

	start_scan: {
		args: { on: 0 },
		call: function(req) {
			if (!is_on(req.args.on)) {
				// Stopping a scan that is not running answers
				// "Failed to stop discovery", which is harmless either way.
				run_btctl('scan off');
				return { success: true };
			}

			// Bounded with --timeout so the popen cannot hang the RPC call.
			// Discovery runs while the command lives and stops when it exits,
			// which is the duration the frontend waits for.
			const output = run_btctl('--timeout=5 scan on');

			if (!bt_ok(output))
				return { success: false, error: 'Starting the scan failed.' };

			return { success: true };
		}
	},

	// No expect/unbuffer dependency: a helper script driving bluetoothctl
	// interactively can never run here (neither is installed), and the old path
	// swallowed the "not found" output and still reported success.
	pair: {
		args: { mac: 'string' },
		call: function(req) {
			if (!valid_mac(req.args.mac)) {
				return { success: false, error: 'A valid MAC address is required.' };
			}

			const mac = trim(req.args.mac);
			const output = run_btctl(`-- pair ${shellquote(mac)}`);

			if (!bt_relaxed(output))
				return { success: false, error: 'Pairing failed: ' + bt_msg(output) };

			// Persist the key so the device reconnects after a reboot.  Trust is
			// best-effort: some controllers reject it, which is not a failure.
			const trust_output = run_btctl(`-- trust ${shellquote(mac)}`);

			return {
				success: true,
				trusted: bt_ok(trust_output)
			};
		}
	},

	connect: {
		args: { mac: 'string' },
		call: function(req) {
			if (!valid_mac(req.args.mac))
				return { success: false, error: 'A valid MAC address is required.' };

			const output = run_btctl(`-- connect ${shellquote(trim(req.args.mac))}`);

			if (!bt_ok(output))
				return { success: false, error: 'Connecting failed: ' + bt_msg(output) };

			return { success: true };
		}
	},

	disconnect: {
		args: { mac: 'string' },
		call: function(req) {
			if (!valid_mac(req.args.mac))
				return { success: false, error: 'A valid MAC address is required.' };

			const output = run_btctl(`-- disconnect ${shellquote(trim(req.args.mac))}`);

			if (!bt_relaxed(output))
				return { success: false, error: 'Disconnecting failed: ' + bt_msg(output) };

			return { success: true };
		}
	},

	remove_device: {
		args: { mac: 'string' },
		call: function(req) {
			if (!valid_mac(req.args.mac))
				return { success: false, error: 'A valid MAC address is required.' };

			const output = run_btctl(`-- remove ${shellquote(trim(req.args.mac))}`);

			if (!bt_relaxed(output))
				return { success: false, error: 'Removing failed: ' + bt_msg(output) };

			return { success: true };
		}
	},

	set_alias: {
		args: { alias: 'string' },
		call: function(req) {
			const alias = trim(req.args.alias);
			if (!alias || length(alias) > 50)
				return { success: false, error: 'Alias must be 1-50 characters.' };

			// bt_alias.sh enforces the same whitelist, which keeps the value safe
			// both for BlueZ and inside a sed replacement.
			if (!match(alias, /^[A-Za-z0-9 ._-]+$/))
				return { success: false, error: 'Alias may only contain letters, digits, spaces, ".", "-" and "_".' };

			const output = run_btctl(`system-alias ${shellquote(alias)}`);

			if (!bt_ok(output))
				return { success: false, error: 'Setting the alias failed.' };

			// BlueZ stores the alias under /etc/bluetooth/keys/<MAC>/settings, so
			// it survives a reboot on its own.

			return { success: true };
		}
	},

	set_codec: {
		args: { data: {} },
		call: function(req) {
			try {
				if (!req.args.data) {
					return { success: false, error: 'Invalid request: "data" object is missing.' };
				}

				const mac = req.args.data.mac;
				const codec = req.args.data.codec;

				if (!valid_mac(mac))
					return { success: false, error: 'A valid MAC address is required in data.' };
				if (!codec)
					return { success: false, error: 'Codec required in data object.' };

				const bluealsa_mac = replace(mac, /:/g, '_');
				const bluealsa_path = `/org/bluealsa/hci0/dev_${bluealsa_mac}/a2dpsrc/sink`;
				const cmd = `bluealsactl codec ${shellquote(bluealsa_path)} ${shellquote(codec)} 2>&1`;

				const handle = popen(cmd, 'r');
				if (!handle) {
					return { success: false, error: 'Failed to execute command via popen.' };
				}

				const output = handle.read('all');
				handle.close();

				if (output && trim(output).length > 0) {
					return { success: false, error: 'Command execution failed.', details: trim(output) };
				}

				return { success: true };
			} catch (e) {
				return { success: false, error: 'An unexpected exception occurred.', details: e.message };
			}
		}
	},

	set_volume: {
		args: { data: {} },
		call: function(req) {
			try {
				if (!req.args.data) {
					return { success: false, error: 'Invalid request: "data" object is missing.' };
				}

				const mac = req.args.data.mac;
				const volume = req.args.data.volume;

				if (!valid_mac(mac)) {
					return { success: false, error: 'A valid MAC address is required in data.' };
				}

				if (volume == null) {
					return { success: false, error: 'Volume required in data object.' };
				}

				const bluealsa_mac = replace(mac, /:/g, '_');
				const bluealsa_path = `/org/bluealsa/hci0/dev_${bluealsa_mac}/a2dpsrc/sink`;
				const cmd = `bluealsactl volume ${shellquote(bluealsa_path)} ${volume} 2>&1`;

				const handle = popen(cmd, 'r');
				if (!handle) {
					return { success: false, error: 'Failed to execute command via popen.' };
				}

				const output = handle.read('all');
				handle.close();

				if (output && trim(output).length > 0) {
					return { success: false, error: 'Command execution failed.', details: trim(output) };
				}

				return { success: true };
			} catch (e) {
				return { success: false, error: 'An unexpected exception occurred.', details: e.message };
			}
		}
	}
};

return { 'luci.bluetooth': methods };