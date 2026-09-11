// Website analytics only. The native app never loads this script.
(() => {
  if (location.origin !== 'https://voxkey.rodrigouroz.com') return;
  // Public, write-only project token. Never use a personal or secret API key here.
  const projectToken = 'phc_BjnBj5vVqcFGnV4zyNx9BhfCSSUzjMt8n3dr5YbimcxA';
  const language = document.documentElement.lang;
  const isTest = new URLSearchParams(location.search).get('analytics_test') === '1';

  // Official PostHog async loader: queues events while the SDK is loading.
  // https://posthog.com/docs/web-analytics/installation/html-snippet
  !function(t,e){var o,n,p,r;e.__SV||(window.posthog && window.posthog.__loaded)||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}p||((p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",p.onerror=function(){p=null},(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r));var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],Object.defineProperty(u,"toString",{configurable:!0,enumerable:!0,writable:!0,value:function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e}}),Object.defineProperty(u.people,"toString",{configurable:!0,enumerable:!0,writable:!0,value:function(){return u.toString(1)+".people (stub)"}}),o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagResult isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey getNextSurveyStep identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

  window.posthog.init(projectToken, {
    api_host: 'https://us.i.posthog.com',
    defaults: '2026-05-30',
    // Keep anonymous visitor identity on this origin, without cross-site cookies.
    persistence: 'localStorage',
    person_profiles: 'never',
    capture_pageview: true,
    capture_pageleave: true,
    capture_performance: true,
    autocapture: true,
    mask_all_text: true,
    mask_all_element_attributes: true,
    mask_personal_data_properties: true,
    disable_session_recording: true,
    disable_surveys: true,
    advanced_disable_feature_flags: true,
    capture_heatmaps: false,
    capture_dead_clicks: false,
    capture_exceptions: false,
    rageclick: false,
    before_send: (event) => {
      if (event) event.properties = { ...event.properties, site: 'voxkey', language, is_test: isTest };
      return event;
    },
  });

  const trackDownload = (event) => {
    if (!event.isTrusted || event.defaultPrevented) return;
    if (event.type === 'click' ? event.button !== 0 : event.button !== 1) return;
    const link = event.target instanceof Element
      ? event.target.closest('a[data-download-placement]') : null;
    if (!link) return;
    const placement = link.dataset.downloadPlacement;
    if (placement !== 'hero' && placement !== 'install') return;

    // Keep the original GitHub URL and never wait for analytics to download.
    try {
      window.posthog.capture('voxkey_download_clicked', {
        placement,
        download_url: link.href,
        release_version: new URL(link.href).pathname.match(/\/releases\/download\/([^/]+)\//)?.[1] || 'unknown',
      }, { transport: 'sendBeacon', send_instantly: true });
    } catch {
      // A blocked or unavailable SDK must not interrupt the native link action.
    }
  };

  document.addEventListener('click', trackDownload);
  document.addEventListener('auxclick', trackDownload);
})();
