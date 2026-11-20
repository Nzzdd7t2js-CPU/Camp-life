export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') {
      return Response.json({ ok: true, app: 'CAMP LIFE', version: '2.0.0' }, {
        headers: { 'Cache-Control': 'no-store' }
      });
    }
    return env.ASSETS.fetch(request);
  }
};
