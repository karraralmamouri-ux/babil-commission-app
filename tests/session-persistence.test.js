const test = require('node:test');
const assert = require('node:assert/strict');

const { loadCurrentApp } = require('./load-current-app');

test('login session survives an application reload in the same browser storage', () => {
  const storage = new Map();
  const firstLoad = loadCurrentApp({ storage });
  const session = {
    access_token: 'access-1',
    refresh_token: 'refresh-1',
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    user: { id: 'user-1' },
  };

  firstLoad.setSbSession(session);
  const secondLoad = loadCurrentApp({ storage });

  assert.deepEqual(JSON.parse(JSON.stringify(secondLoad.getSbSession())), session);
});

test('expired access token is refreshed and the rotated session is persisted', async () => {
  const storage = new Map();
  let refreshRequest;
  const refreshedSession = {
    access_token: 'access-2',
    refresh_token: 'refresh-2',
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    user: { id: 'user-1' },
  };
  const app = loadCurrentApp({
    storage,
    fetch: async (url, options) => {
      refreshRequest = { url, options };
      return {
        ok: true,
        status: 200,
        async text() {
          return JSON.stringify(refreshedSession);
        },
      };
    },
  });
  app.setSbSession({
    access_token: 'expired-access',
    refresh_token: 'refresh-1',
    expires_at: Math.floor(Date.now() / 1000) - 10,
    user: { id: 'user-1' },
  });

  const result = await app.refreshSbSession();

  assert.match(refreshRequest.url, /\/auth\/v1\/token\?grant_type=refresh_token$/);
  assert.deepEqual(JSON.parse(refreshRequest.options.body), { refresh_token: 'refresh-1' });
  assert.equal(result.access_token, 'access-2');
  assert.equal(app.getSbSession().refresh_token, 'refresh-2');
});

test('session expiry check refreshes only near expiration', () => {
  const { sessionExpiresSoon } = loadCurrentApp();
  const now = Math.floor(Date.now() / 1000);

  assert.equal(sessionExpiresSoon({ expires_at: now + 30 }), true);
  assert.equal(sessionExpiresSoon({ expires_at: now + 3600 }), false);
});

test('a temporary network failure does not erase the saved refresh token', async () => {
  const app = loadCurrentApp({
    fetch: async () => {
      throw new Error('offline');
    },
  });
  app.setSbSession({ access_token: 'expired', refresh_token: 'keep-me', expires_at: 0 });

  await assert.rejects(app.refreshSbSession(), (error) => error.status === 0);
  assert.equal(app.getSbSession().refresh_token, 'keep-me');
});
