'use strict';
'require network';

/*
 * Minimal LuCI protocol class for the netifd "wwan" proto handler.
 *
 * The OpenWrt "wwan" package (pulled in by uqmi/umbim) registers a
 * netifd protocol handler named "wwan", but no LuCI protocol class
 * file exists for it anywhere in the LuCI feeds.  Current LuCI
 * enumerates every netifd handler and tries to load a matching
 * /luci-static/resources/protocol/<name>.js class file; the missing
 * wwan.js yields a NetworkError 404 which breaks the status overview
 * rendering.  No interface here uses proto "wwan" (the modem is
 * managed via proto "modemmanager"), so a minimal registration is
 * sufficient.
 */

return network.registerProtocol('wwan', {
	getI18n: function() {
		return _('WWAN');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'wwan-%s'.format(this.sid);
	},

	getPackageName: function() {
		return 'wwan';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	}
});
