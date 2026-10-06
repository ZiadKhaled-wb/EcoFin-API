/** Local Mailpit only. Raw tokens live in test memory, never in API responses or database fixtures. */
export async function readInviteToken(email: string): Promise<string> {
  const base = process.env['MAILPIT_URL'] ?? 'http://127.0.0.1:54324';
  for (let attempt = 0; attempt < 50; attempt++) {
    const list = (await (
      await fetch(`${base}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`)
    ).json()) as { messages: { ID: string }[] };
    const id = list.messages[0]?.ID;
    if (id) {
      const message = (await (await fetch(`${base}/api/v1/message/${id}`)).json()) as {
        Text: string;
      };
      const token = /#token=([A-Za-z0-9_-]{43})/.exec(message.Text)?.[1];
      if (token) return token;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('Local invite email not received.');
}
