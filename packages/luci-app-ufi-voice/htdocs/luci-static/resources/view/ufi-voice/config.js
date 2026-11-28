'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';

function good(text) {
	return E('strong', { 'style': 'color:#2e7d32' }, text);
}

function bad(text) {
	return E('strong', { 'style': 'color:#c62828' }, text);
}

function dim(text) {
	return E('span', { 'style': 'color:#888' }, text);
}

function field(label, value) {
	return E('div', { 'class': 'cbi-value' }, [
		E('div', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, [ value ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ufivoice'),
			uci.load('network'),
			L.resolveDefault(fs.exec('/usr/sbin/ufi-voice-status', []), null)
		]);
	},

	render: function(data) {
		var st = null;

		// load() 返回 Promise.all([uci.load('ufivoice'), uci.load('network'), fs.exec(...)]),
		// 所以 fs.exec 的结果在 data[2] —— 不是 data[1](那是 uci.load('network') 的返回值,
		// 没有 .stdout 字段)。取错索引会让 st 恒为 null、Registered 列恒显 "—"。
		try {
			if (data[2] && data[2].stdout)
				st = JSON.parse(data[2].stdout);
		}
		catch (e) {
			st = null;
		}

		var m, s, o;

		// 设备自身的 LAN IP：软电话注册时连这个地址。动态读 network.lan.ipaddr，
		// 用户改了 LAN IP 则提示随之更新；读不到时回退默认网关地址。
		var lanip = uci.get('network', 'lan', 'ipaddr') || '192.168.1.1';

		m = new form.Map('ufivoice', _('Phone'),
			_('Calls are carried by the mobile network (VoLTE) and handed to a Bluetooth ' +
			  'headset and/or SIP phones on this device. This page configures the SIP ' +
			  'accounts, where calls go, and the audio path. Changes take effect as soon ' +
			  'as they are applied; a call in progress is not interrupted.'));

		/* ---------------------------------------------------------------- */
		/* Status                                                           */
		/* ---------------------------------------------------------------- */

		s = m.section(form.NamedSection, 'status', '_status');
		s.render = function() {
			var rows = [];

			if (st == null) {
				rows.push(field(_('Status helper'), bad(_('not available'))));
			}
			else {
				var mstate = st.modem_state || 'unknown';
				var modem_up = (mstate === 'registered' || mstate === 'connected');
				var modem = modem_up ? good(mstate) : bad(mstate);

				if (st.modem_operator)
					modem = E('span', {}, [
						modem, ' \u2014 ', st.modem_operator,
						st.modem_signal ? ' (' + st.modem_signal + '%)' : '',
						st.modem_tech ? ' \u00b7 ' + st.modem_tech : ''
					]);

				rows.push(field(_('Modem'), modem));
				rows.push(field(_('IMS registration'),
					(st.ims === 'registered') ? good(st.ims) : bad(st.ims)));

				/* The audio services live in the modem's firmware and stop
				 * answering for good if they ever time out; the kernel logs
				 * "failed -110" and only a reboot brings them back. */
				if (st.dsp === 'hung')
					rows.push(field(_('Audio DSP'), E('span', {}, [
						bad(_('not responding')),
						' \u2014 ',
						_('calls connect but carry no audio; reboot the device')
					])));

				var svcs = [];

				[
					['ufi_voiced', _('Call daemon')],
					['imsdcm', _('IMS data service')],
					['asterisk', 'Asterisk'],
					['hfp_ag', _('Bluetooth HFP')],
					['voicebridge', _('Audio bridge')]
				].forEach(function(p) {
					svcs.push(E('span', { 'style': 'margin-right:1.2em;white-space:nowrap' }, [
						p[1] + ': ',
						(st[p[0]] === 'running') ? good(_('running')) : dim(_('stopped'))
					]));
				});

				rows.push(field(_('Services'), E('span', {}, svcs)));
				rows.push(field(_('Active calls'), String(st.calls || 0)));
			}

			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('div', { 'class': 'cbi-section-node' }, rows)
			]);
		};

		/* ---------------------------------------------------------------- */
		/* Service                                                          */
		/* ---------------------------------------------------------------- */

		s = m.section(form.NamedSection, 'main', 'ufivoice', _('Service'));

		o = s.option(form.Flag, 'volte', _('Run the IMS data service'),
			_('Lets the modem register for VoLTE. Without it the modem has no IMS ' +
			  'data connection and calls fall back to the circuit-switched network ' +
			  '(which this device does not have on 4G).'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Where calls go'));
		o.value('both', _('Bluetooth headset and SIP phones'));
		o.value('bt', _('Bluetooth headset only'));
		o.value('asterisk', _('SIP phones only'));
		o.value('none', _('Answer on the device, no audio routing'));
		o.default = 'both';
		o.rmempty = false;

		o = s.option(form.Value, 'autoanswer', _('Auto-answer after (seconds)'),
			_('0 never answers by itself.'));
		o.datatype = 'range(0,60)';
		o.placeholder = '0';

		o = s.option(form.Flag, 'manage_answer', _('Manage auto-answer'),
			_('Stops the ModemManager auto-answer service while this daemon runs, ' +
			  'so the two cannot both answer a call.'));

		/* ---------------------------------------------------------------- */
		/* Notifications                                                    */
		/* ---------------------------------------------------------------- */

		s = m.section(form.NamedSection, 'main', 'ufivoice', _('Incoming call notifications'),
			_('A phone whose SIP client has been suspended by the system (iOS does ' +
			  'this to any app in the background) has no registration, so Asterisk ' +
			  'cannot ring it at all. A push notification wakes the phone; opening ' +
			  'the client re-registers it and the call is rung while it still rings. ' +
			  'Messages are sent through ntfy, which needs no account.'));

		o = s.option(form.Flag, 'notify', _('Send a notification'),
			_('Sends one message per incoming call, with the caller\'s number.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'ntfy_url', _('ntfy server'),
			_('The server to post to. Use https://ntfy.sh, or your own if you run one.'));
		o.placeholder = 'https://ntfy.sh';
		o.depends('notify', '1');

		o = s.option(form.Value, 'ntfy_topic', _('Topic'),
			_('The topic your phone subscribes to in the ntfy app. Anyone who knows ' +
			  'it can read the messages, so pick something unguessable.'));
		o.placeholder = 'ufi-7f3c9a1e';
		o.depends('notify', '1');

		o = s.option(form.Value, 'ntfy_token', _('Access token'),
			_('Only for a server with access control. Left empty, no token is sent.'));
		o.password = true;
		o.depends('notify', '1');

		o = s.option(form.Value, 'ntfy_click', _('Open on tap'),
			_('A link to open when the notification is tapped, instead of the ntfy ' +
			  'app. Point it at a URI your softphone registers — for example ') +
			'<code>sip:100@' + lanip + '</code>' +
			_(", or the app's own scheme such as " +
			  '<code>linphone:</code> or <code>zoiper:</code>. One tap then opens the ' +
			  'client and re-registers it. Does nothing if no app claims that URI. ' +
			  'Leave empty to keep opening the ntfy app.'));
		o.placeholder = 'sip:100@' + lanip;
		o.depends('notify', '1');

		o = s.option(form.Value, 'ntfy_password', _('Topic password'),
			_('Encrypts the message end to end, so the server only stores ' +
			  'ciphertext. Set the same password on the topic in the app ' +
			  '(topic menu, End-to-end encryption). Left empty, the message is ' +
			  'sent in the clear and anyone who knows the topic can read it.'));
		o.password = true;
		o.depends('notify', '1');

		/* ---------------------------------------------------------------- */
		/* SIP accounts                                                     */
		/* ---------------------------------------------------------------- */

		s = m.section(form.GridSection, 'phone', _('SIP accounts'),
			_('Phones that register to Asterisk on this device. The dialplan sends ' +
			  'every call to the mobile network, and incoming mobile calls ring all ' +
			  'accounts at once. Leave the password empty to have one generated.'));
		s.anonymous = true;
		s.addremove = true;

		o = s.option(form.Value, 'number', _('Number'));
		o.datatype = 'rangelength(2,20)';
		o.placeholder = '100';
		o.rmempty = false;

		o = s.option(form.Value, 'password', _('Password'));
		o.placeholder = _('generated');
		o.description = _('Also written to /etc/asterisk/ufi-voice-phones.txt on the device.');

		o = s.option(form.DummyValue, '_registered', _('Registered'));
		o.rawhtml = true;
		o.cfgvalue = function(section_id) {
			// 本 section 是匿名 GridSection：不同 LuCI 版本里 section_id 可能是
			// uci 名(p1/p2)也可能是数字索引，两种都试，取不到 number 就显示 "—"。
			var num = uci.get('ufivoice', section_id, 'number');
			if (!num) {
				var secs = uci.sections('ufivoice', 'phone') || [];
				var idx = parseInt(section_id, 10);
				if (!isNaN(idx) && secs[idx - 1])
					num = uci.get('ufivoice', secs[idx - 1], 'number');
			}

			var list = (st && st.sip) ? st.sip : [];

			for (var i = 0; i < list.length; i++) {
				if (list[i].number !== num)
					continue;

				if (list[i].status === 'down')
					return E('span', { 'style': 'color:#c62828' }, _('no'));

				return E('span', { 'style': 'color:#2e7d32' }, [
					_('yes'),
					(list[i].host ? ' \u00a0' + list[i].host : '')
				]);
			}

			// 区分两种 "—"：st 为空 = 状态脚本没跑通(fs.exec 失败/超时)，
			// 与"该账号确实没有注册"不一样，后者不该用同一个破折号糊过去。
			return E('span', { 'style': 'color:#888' },
				st ? '\u2014' : _('status unavailable'));
		};
		/* This cell is inside a GridSection (a table). A DummyValue in a table
		 * is rendered by GridSection.renderTextValue(), which calls
		 * textvalue(). The base textvalue() passes the value through the
		 * '%h' HTML-escape filter, which turns our DOM node into the string
		 * "[object HTMLSpanElement]" and, for plain HTML strings, escaped
		 * source. Override textvalue() to return the node unchanged so the
		 * span is inserted as a real element and the status colour is shown. */
		o.textvalue = function(section_id) {
			var v = this.cfgvalue(section_id);
			return (v != null) ? v : this.default;
		};

		/* ---------------------------------------------------------------- */
		/* Audio                                                            */
		/* ---------------------------------------------------------------- */

		s = m.section(form.NamedSection, 'main', 'ufivoice', _('Audio'));

		o = s.option(form.Value, 'jitter_ms', _('Jitter buffer (ms)'),
			_('Audio from the phones is buffered this long before it is played into ' +
			  'the call. Raise it if the far end hears choppy speech over Wi-Fi; ' +
			  'lower it to reduce delay. 40 ms suits a wired or good Wi-Fi link.'));
		o.datatype = 'range(20,500)';
		o.placeholder = '40';

		o = s.option(form.ListValue, 'pcm_rate', _('PCM rate'),
			_('Sample rate of the in-call audio device. 48 kHz gives 10 ms periods, ' +
			  'which is what the DSP expects.'));
		o.value('48000', '48000 Hz');
		o.value('16000', '16000 Hz');
		o.default = '48000';

		o = s.option(form.Flag, 'host_tx_mute', _('Mute the unused microphone port'),
			_('Keeps the internal Bluetooth SCO microphone out of the call, so only ' +
			  'the phones supply uplink audio.'));

		o = s.option(form.Flag, 'bridge_debug', _('Log audio statistics'),
			_('Writes a voicebridge statistics line to the system log every 5 seconds. ' +
			  'Useful when diagnosing choppy audio; leave off otherwise.'));

		/* ---------------------------------------------------------------- */
		/* Bluetooth                                                        */
		/* ---------------------------------------------------------------- */

		s = m.section(form.NamedSection, 'main', 'ufivoice', _('Bluetooth headset'));

		o = s.option(form.Value, 'bt_headset', _('Headset address'),
			_('MAC address of the headset to connect to, e.g. 00:11:22:33:44:55. ' +
			  'Pair it first with bluetoothctl.'));
		o.placeholder = '00:11:22:33:44:55';

		o = s.option(form.Value, 'bt_reconnect_max', _('Reconnect backoff (seconds)'),
			_('How long to keep paging a disconnected headset, doubling from 60 s. ' +
			  'Each page briefly blinds the Wi-Fi station (shared 2.4 GHz radio). ' +
			  '0 never pages.'));
		o.datatype = 'range(0,3600)';
		o.placeholder = '900';

		/* ---------------------------------------------------------------- */
		/* Advanced                                                         */
		/* ---------------------------------------------------------------- */

		s = m.section(form.NamedSection, 'main', 'ufivoice', _('Advanced'));

		o = s.option(form.ListValue, 'session', _('Voice session'),
			_('DSP voice path used for call audio. Auto picks VoLTE while IMS is ' +
			  'registered and the circuit-switched session otherwise.'));
		o.value('auto', _('Auto'));
		o.value('volte', _('VoLTE'));
		o.value('cs', _('Circuit switched'));
		o.default = 'auto';

		o = s.option(form.Value, 'audiosocket_port', _('AudioSocket port'));
		o.datatype = 'port';
		o.placeholder = '9092';

		o = s.option(form.Value, 'ami_user', _('Asterisk AMI user'));
		o.placeholder = 'ufivoice';

		o = s.option(form.Value, 'ami_secret', _('Asterisk AMI password'),
			_('Left empty, a random password is generated and shared with Asterisk.'));
		o.password = true;

		o = s.option(form.Value, 'wan_iface', _('Mobile interface'),
			_('netifd interface of the mobile data connection.'));
		o.placeholder = 'modem';

		o = s.option(form.Value, 'ims_kick_after', _('Restart IMS after (seconds)'),
			_('Restarts the IMS data service when IMS has had no connection for this ' +
			  'long, doubling up to one hour while that does not help. 0 never.'));
		o.datatype = 'range(0,3600)';
		o.placeholder = '180';

		/* ---------------------------------------------------------------- */
		/* Apply                                                            */
		/* ---------------------------------------------------------------- */

		/* The JS form API has no on_after_commit hook, so the page footer
		 * button is overridden: save, commit, regenerate the Asterisk
		 * configuration from the new accounts, then reload the page.
		 *
		 * The commit is a "checked" apply, which rolls back unless it is
		 * confirmed within a few seconds; confirm it before reloading, or
		 * the page reload would cancel the rollback timer's confirmation
		 * and the changes would be reverted behind the user's back. */
		this.handleSaveApply = function(ev, mode) {
			return this.handleSave(ev).then(function() {
				return uci.apply();
			}).catch(function(err) {
				/* rpcd answers uci/apply with "No data received" when the
				 * save already committed the section, so there is nothing
				 * left for apply to do. The configuration is on disk, so
				 * carry on instead of reporting a failure that did not
				 * happen. Anything else is a real error. */
				if (String(err).indexOf('No data') === -1)
					throw err;
			}).then(function() {
				return new Promise(function(resolve) {
					window.setTimeout(resolve, 2000);
				});
			}).then(function() {
				return L.resolveDefault(uci.callConfirm(), null);
			}).then(function() {
				return fs.exec('/usr/sbin/ufi-voice-apply', []);
			}).then(function() {
				window.location.reload();
			}).catch(function(err) {
				ui.addNotification(null,
					E('p', _('Saved, but applying failed: ') + (err || '')),
					'danger');
			});
		};

		return m.render();
	}
});
