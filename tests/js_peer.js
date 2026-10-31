// JS 2.0.2 peer for tests/js_parity_regression.gd: joins PARITY_CHANNEL on the
// token lane, publishes an object, and requires the Godot client's object to
// arrive as an object.
// Usage: PARITY_CHANNEL=<name> node tests/js_peer.js   (needs @oddsockets/js installed)
const { OddSockets } = require('@oddsockets/js');
const channelName = process.env.PARITY_CHANNEL;
const guestUrl = process.env.GUEST_JWT_URL || 'https://cropsicles.com/api/auth/guest';
const tokenUrl = 'https://connect.oddsockets.tyga.network/v1/token';

async function post(url, body, headers = {}) {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  return r.json();
}

(async () => {
  const guest = await post(guestUrl, { deviceId: `js-peer-${Date.now()}` });
  const tokenProvider = async () => {
    const t = await post(tokenUrl, {}, { Authorization: `Bearer ${guest.token}` });
    return { token: t.token, expiresAt: t.expiresAt };
  };
  const client = new OddSockets({ tokenProvider, autoConnect: false });
  client.on('error', () => {});
  await client.connect();
  let fromGodot = null;
  await client.channel(channelName).subscribe((m) => {
    const body = m && m.message !== undefined ? m.message : m;
    if (body && typeof body === 'object' && body.from === 'godot') fromGodot = body;
  });
  const deadline = Date.now() + 90000;
  while (!fromGodot && Date.now() < deadline) {
    await client.channel(channelName).publish({ from: 'js', at: Date.now() });
    await new Promise((r) => setTimeout(r, 2000));
  }
  console.log(fromGodot ? `[PASS] JS peer received Godot object as object: ${JSON.stringify(fromGodot)}` : '[FAIL] JS peer never received the Godot object');
  client.disconnect();
  process.exit(fromGodot ? 0 : 1);
})().catch((e) => { console.error('[FAIL] js peer error', e.message); process.exit(3); });
