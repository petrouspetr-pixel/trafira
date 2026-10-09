// SPDX-License-Identifier: Apache-2.0
'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

function element(tag, attrs, children) { return E(tag, attrs, typeof children === 'string' ? [children] : children); }

var status = rpc.declare({ object: 'luci.trafira_warp', method: 'status', expect: {} });
var action = rpc.declare({ object: 'luci.trafira_warp', method: 'action', params: ['request'], expect: {} });
var errors = {
 busy: _('Another operation is running. Try again when it finishes.'),
 conflict: _('Settings changed. Open a new preview.'),
 recovery_error: _('Recovery failed. The backup has been retained.'),
 recovery_required: _('Restore the unfinished Trafira operation first.'),
 storage_unavailable: _('Not enough storage or private state is unavailable.'),
 references_exist: _('Remove all Trafira references to this WARP interface first.'),
 component_not_installed: _('Install the complete WARP component first.'),
 component_unavailable: _('WARP is unavailable. Check the installed package family.'),
 registration_failed: _('The Cloudflare registration API is unavailable.'),
 https_probe_failed: _('The tunnel did not pass the HTTPS check.'),
 cancelled: _('Operation cancelled; partial test results are retained.'),
 selection_required: _('Select and apply an endpoint first.'),
 stale_candidate: _('The candidate expired. Run discovery again.'),
 transport_unhealthy: _('Start WARP and run a successful HTTPS check first.')
};
return view.extend({
 handleSave: null, handleSaveApply: null, handleReset: null,
 callAction: function(request) { return action(JSON.stringify(request)); },
 load: function() { return status().catch(function(){ return {success:false,error:'component_unavailable'}; }); },
 notify: function(result) {
  if (!result || result.success === false)
   ui.addNotification(null, element('p', {}, errors[result && result.error] || _('The operation failed. Check status and retry.')), 'error');
 },
 refresh: function() {
  var self=this;
  return status().then(function(data){self.state=data;self.draw();}).catch(function(){self.notify({error:'component_unavailable'});});
 },
 act: function(request) {
  var self=this;
  if(self.pending || (self.state && self.state.job && self.state.job.running && request.action !== 'cancel'))return Promise.resolve();
  self.pending=true;self.draw();
  return self.callAction(request).then(function(result){self.notify(result);return self.refresh();})
   .catch(function(){self.notify({error:'component_unavailable'});})
   .finally(function(){self.pending=false;self.draw();});
 },
 confirm: function(request,title,description,terms) {
  var self=this,content=[element('p',{},description)];
  if(terms)content.push(element('p',{},[element('a',{href:'https://www.cloudflare.com/application/terms/',target:'_blank',rel:'noopener noreferrer'},_('Cloudflare terms of service'))]));
  content.push(element('div',{class:'right'},[
   element('button',{class:'btn',click:function(){ui.hideModal();}},_('Cancel')),
   element('button',{class:'btn cbi-button-action',click:function(){ui.hideModal();self.act(request);}},terms?_('Accept and register'):_('Confirm'))
  ]));
  ui.showModal(title,content);
 },
 openPreview: function(removal) {
  var self=this;if(self.pending || self.state.job && self.state.job.running)return Promise.resolve();
  self.pending=true;self.preview=null;self.draw();
  return self.callAction({action:removal?'preview_detach':'preview_attach'}).then(function(result){
   if(!result || !result.success){self.notify(result);return;}
   self.preview=result;
   ui.showModal(_('Review Trafira changes'),[
    element('p',{},removal?_('After detaching, traffic follows the remaining Trafira rules and default route.'):_('A protected WARP section will be created. Choose sites or devices in Trafira afterwards.')),
    element('ul',{},(result.changes||[]).map(function(change){return element('li',{},String(change.section)+' — '+({added:_('Added'),removed:_('Removed'),changed:_('Changed')}[change.change]||_('Changed')));})),
    element('div',{class:'right'},[
     element('button',{class:'btn',click:function(){self.preview=null;ui.hideModal();}},_('Cancel')),
     element('button',{class:'btn cbi-button-apply',click:function(){ui.hideModal();self.applyPreview();}},_('Apply reviewed changes'))
    ])
   ]);
  }).catch(function(){self.notify({error:'component_unavailable'});}).finally(function(){self.pending=false;self.draw();});
 },
 applyPreview: function() {
  var preview=this.preview;this.preview=null;
  if(!preview)return Promise.resolve();
  return this.act({action:preview.removal?'detach':'attach',preview_id:preview.preview_id,expected_digest:preview.expected_digest});
 },
 button: function(label,callback,disabled) {
  return element('button',{class:'btn cbi-button-action',disabled:!!disabled,click:callback},label);
 },
 draw: function() {
  if(!this.panel)return;
  var self=this,s=this.state||{},j=s.job||{},busy=this.pending||j.running,items=[];
  function button(label,fn,disabled){return self.button(label,fn,busy||disabled);}
  items.push(element('p',{},_('Registration')+': '+(s.registered?_('Present'):_('Not registered'))));
  items.push(element('p',{},_('Tunnel')+': '+(s.running?_('Running'):s.enabled?_('Stopped; recovery pending'):_('Disabled'))));
  items.push(element('p',{},_('Handshake age (seconds)')+': '+(s.handshake_age==null?_('Unknown'):String(s.handshake_age))));
  items.push(element('p',{},_('Last HTTPS check')+': '+(s.https_ok?_('Passed'):_('Not confirmed'))));
  if(s.endpoint)items.push(element('p',{},_('Endpoint')+': '+String(s.endpoint)));
  if(!s.success || j.success===false)items.push(element('p',{},errors[s.error||j.error]||_('The operation failed. Check status and retry.')));
  if(j.recovery_pending)items.push(element('p',{},_('An unfinished operation needs recovery. Retry an action to restore its backup first.')));
  if(j.running)items.push(element('p',{},_('An operation is running. You can close this page; it will continue.')));
  items.push(element('div',{class:'cbi-section'},[
   button(_('Register'),function(){self.confirm({action:'register'},_('Register WARP'),_('Create a Cloudflare registration, discover an endpoint and start the tunnel. No Trafira routing rules are added until you attach it.'),true);},s.registered),
   button(_('Enable'),function(){self.act({action:'enable'});},!s.registered||s.running),
   button(_('Disable'),function(){self.confirm({action:'disable'},_('Disable WARP'),_('Traffic assigned to WARP in Trafira will be blocked until the tunnel is enabled again.'));},!s.enabled),
   button(_('Reconnect'),function(){self.act({action:'reconnect'});},!s.enabled),
   button(_('Quick discovery'),function(){self.act({action:'scan_start',mode:'quick'});},!s.registered),
   button(_('Full discovery'),function(){self.act({action:'scan_start',mode:'full'});},!s.registered)
  ]));
  if(s.candidate)items.push(element('div',{},[
   element('p',{},_('Candidate')+': '+String(s.candidate.endpoint)),
   button(_('Apply candidate'),function(){self.act({action:'scan_apply',candidate_id:s.candidate.candidate_id});})
  ]));
  items.push(element('div',{},[
   button(_('Attach to Trafira'),function(){self.openPreview(false);},!s.running),
   button(_('Detach from Trafira'),function(){self.openPreview(true);}),
   button(_('Delete local registration'),function(){self.confirm({action:'unregister'},_('Delete local registration'),_('The tunnel and its local credentials will be removed. Cloudflare-side registration is not revoked. All Trafira references must be removed first.'));},!s.registered)
  ]));
  var duration=element('select',{change:function(ev){self.duration=Number(ev.target.value);}},[15,30,45,60].map(function(n){return element('option',{value:String(n),selected:n===(self.duration||30)},String(n)+' '+_('minutes'));}));
  items.push(element('div',{},[
   element('h3',{},_('Service availability test')),duration,
   button(_('Test Google, ChatGPT, Gemini, Grok and Cloudflare'),function(){self.act({action:'test_start',duration:Number(duration.value||30),services:['google','chatgpt','gemini','grok','cloudflare']});},!s.running)
  ]));
  if(s.test && s.test.summary){var t=s.test.summary;items.push(element('p',{},
   _('Samples')+': '+String(t.samples||0)+'; '+_('Transport errors')+': '+String(t.transport_errors||0)+'; '+_('HTTP 403/429')+': '+String(t.http_restricted||0)+'; median / p95 (ms): '+String(t.median||0)+' / '+String(t.p95||0)));}
  if(j.running)items.push(self.button(_('Cancel operation'),function(){self.act({action:'cancel',job_id:j.job_id});},self.pending));
  this.panel.replaceChildren.apply(this.panel,items);
 },
 render: function(data) {
  var self=this;this.state=data;this.pending=false;this.preview=null;
  this.panel=element('div');this.draw();
  this.poller=function(){return self.refresh();};poll.add(this.poller,3);
  this.unload=function(){self.handleUnload();};window.addEventListener('pagehide',this.unload);
  return element('div',{},[element('h2',{},_('WARP for Trafira')),element('p',{},_('Optional tunnel for selected sites and devices. WARP does not guarantee access to every service or a particular country.')),this.panel]);
 },
 handleUnload: function(){if(this.poller)poll.remove(this.poller);this.poller=null;if(this.unload)window.removeEventListener('pagehide',this.unload);this.unload=null;}
});
