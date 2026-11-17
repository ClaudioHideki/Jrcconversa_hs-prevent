const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.JRC_PLAYWRIGHT_MODULE);
const out = path.resolve('tmp/ci-evidence');
const fixture = JSON.parse(fs.readFileSync(path.join(out, 'browser-fixtures.json'), 'utf8'));
const origin = 'http://127.0.0.1:18417';
const results = [], errors = [], editorActions = [];
let page, context;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(check, description) {
  for (let i = 0; i < 160; i++) { if (await check()) return; await sleep(100); }
  throw new Error(`Timed out: ${description}`);
}
async function clearEditor(editor) {
  await editor.click();
  await editor.press('Escape');
  await editor.press('Control+Home');
  await editor.press('Control+Shift+End');
  const selected = await editor.evaluate(node => ({
    beforeLength: node.innerText.length,
    selectedLength: window.getSelection().toString().length,
    focused: document.activeElement === node,
  }));
  await editor.press('Backspace');
  editorActions.push({ ...selected, afterLength: await editor.innerText().then(text => text.length) });
}
async function setMessage(editor, counter, text) {
  await clearEditor(editor);
  await waitFor(async () => (await counter.innerText()).includes('0 / 160'), 'empty counter');
  const responsePromise = page.waitForResponse(response => response.url().endsWith('/sms_preview') && response.request().method() === 'POST' && response.request().postDataJSON().content === text);
  // Paste into the empty editor so its existing typed-variable input rule does
  // not expand the template before the request reaches the Rails renderer.
  await editor.fill(text);
  const response = await responsePromise;
  assert.equal(response.status(), 200);
  const result = await response.json();
  await waitFor(async () => result.reason ? (await counter.innerText()).includes('Não é possível confirmar') : (await counter.innerText()).includes(`${result.length} / ${result.limit}`), 'server preview');
  return response.request().postDataJSON().content;
}
async function test(name, fn) {
  await fn();
  results.push({ name, status: 'PASS' });
  console.log(`PASS: ${name}`);
}
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.JRC_CHROME_PATH, headless: true, args: ['--no-sandbox'] });
  try {
    context = await browser.newContext({ viewport: { width: 1600, height: 1000 }, locale: 'pt-BR' });
    await context.route('**/*', route => new URL(route.request().url()).origin === origin ? route.continue() : route.abort('blockedbyclient'));
    page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`${origin}/app/login`, { waitUntil: 'networkidle' });
    await page.getByTestId('email_input').fill('browser@example.invalid');
    await page.getByTestId('password_input').fill('Isolated-browser-only-2026!');
    await page.getByTestId('submit_button').click();
    await page.waitForURL(url => !url.pathname.includes('/login'));
    const conversation = fixture.conversations[0];
    await page.goto(`${origin}/app/accounts/${fixture.account_id}/inbox/${fixture.inbox_id}/conversations/${conversation.display_id}`, { waitUntil: 'networkidle' });
    let editor = page.locator('[contenteditable="true"].ProseMirror');
    let counter = page.getByTestId('flux-sms-counter');
    let send = page.getByRole('button', { name: /^Enviar SMS/ });
    await counter.waitFor();
    for (const length of [159, 160, 161]) {
      await test(`Reply ${length}`, async () => {
        await setMessage(editor, counter, 'a'.repeat(length));
        assert.ok((await counter.innerText()).includes(`${length} / 160`));
        assert.equal(await send.isDisabled(), length > 160);
      });
    }
    await page.screenshot({ path: path.join(out, 'browser-reply-161.png'), fullPage: true });
    await test('Reply Liquid expands to 161', async () => {
      await setMessage(editor, counter, '{{contact.name}}');
      assert.ok((await counter.innerText()).includes('161 / 160'));
      assert.equal(await send.isDisabled(), true);
    });
    let sends = 0;
    let failure = 422;
    await context.route('**/conversations/*/messages', async route => {
      if (route.request().method() !== 'POST') return route.continue();
      sends++;
      await sleep(400);
      return failure === 'network' ? route.abort('failed') : route.fulfill({ status: failure, contentType: 'application/json', body: '{"error":"Isolated rejection"}' });
    });
    await test('Reply invalid shortcuts never call sending API', async () => {
      await editor.press('Enter'); await editor.press('Control+Enter'); await sleep(400);
      assert.equal(sends, 0);
    });
    for (const code of [422, 429, 500, 'network']) {
      await test(`Reply draft survives ${code}`, async () => {
        failure = code;
        const source = await setMessage(editor, counter, 'Olá {{agent.name}}');
        const refreshPromise = page.waitForResponse(response => response.url().endsWith('/sms_preview') && response.request().method() === 'POST');
        await send.click();
        const refresh = await refreshPromise;
        assert.equal(refresh.request().postDataJSON().content, source);
        await waitFor(async () => !(await send.isDisabled()), 'failed request released');
      });
    }
    await test('Actual isolated DLR updates database and UI to two checks', async () => {
      const bubble = page.locator(`#message${fixture.delivery_id}`);
      assert.equal(await bubble.locator('.i-lucide-check').count(), 1);
      await bubble.locator('.i-lucide-check').hover();
      await waitFor(async () => (await page.locator('body').innerText()).includes('Aguardando confirmação de entrega'), 'exact tooltip');
      const response = await context.request.post(`${origin}/f?t=${fixture.callback_token}`, { data: {
        telefone: '5511999999999', id: '991234567', idParceiro: fixture.source_id,
        data: new Date().toISOString(), status: 'ENTREGUE',
      } });
      assert.equal(response.status(), 200);
      assert.equal(await response.text(), 'OK');
      await waitFor(async () => (await bubble.locator('.i-lucide-check-check').count()) === 1, 'real isolated ActionCable delivered');
    });
    await page.screenshot({ path: path.join(out, 'browser-delivered.png'), fullPage: true });
    await test('A to B to A navigation keeps the document and history', async () => {
      const epoch = await page.evaluate(() => performance.timeOrigin);
      const b = fixture.conversations[1];
      await page.locator(`a[href$="/conversations/${b.display_id}"]`).first().click();
      await page.waitForURL(url => url.pathname.endsWith(`/conversations/${b.display_id}`));
      await page.locator(`a[href$="/conversations/${conversation.display_id}"]`).first().click();
      await page.waitForURL(url => url.pathname.endsWith(`/conversations/${conversation.display_id}`));
      assert.equal(await page.evaluate(() => performance.timeOrigin), epoch);
      assert.ok((await page.locator('body').innerText()).includes(conversation.history));
    });
    await page.locator('button:has(.i-lucide-pen-line)').first().click();
    const popup = page.getByTestId('compose-conversation-form');
    await popup.waitFor();
    await popup.getByPlaceholder(/Digite pelo menos/).fill('aaaa');
    await popup.getByRole('button').filter({ hasText: conversation.name }).first().click();
    await popup.getByRole('button', { name: /SMS_2 Teste Isolado/ }).click();
    editor = popup.locator('[contenteditable="true"]').first();
    counter = popup.getByTestId('flux-sms-counter');
    send = popup.getByRole('button', { name: /^Enviar/ });
    let newSends = 0;
    await context.route('**/conversations', async route => {
      if (route.request().method() !== 'POST') return route.continue();
      newSends++;
      await sleep(400);
      return failure === 'network' ? route.abort('failed') : route.fulfill({ status: failure, contentType: 'application/json', body: '{"error":"Isolated rejection"}' });
    });
    for (const length of [159, 160, 161]) {
      await test(`New conversation ${length}`, async () => {
        await setMessage(editor, counter, 'a'.repeat(length));
        assert.ok((await counter.innerText()).includes(`${length} / 160`));
        assert.equal(await send.isDisabled(), length > 160);
      });
    }
    await test('New conversation invalid shortcuts never send', async () => {
      await editor.press('Enter'); await editor.press('Control+Enter'); await sleep(400);
      assert.equal(newSends, 0);
    });
    await test('New conversation Liquid expands to 161', async () => {
      await setMessage(editor, counter, '{{contact.name}}');
      assert.ok((await counter.innerText()).includes('161 / 160'));
      assert.equal(await send.isDisabled(), true);
    });
    await page.screenshot({ path: path.join(out, 'browser-compose-liquid.png'), fullPage: true });
    await test('Future conversation ID has no approximate count', async () => {
      await setMessage(editor, counter, '{{conversation.id}}');
      assert.ok(!(await counter.innerText()).includes(' / '));
      assert.equal(await send.isDisabled(), true);
    });
    for (const code of [422, 429, 500, 'network']) {
      await test(`New conversation preserves draft after ${code}`, async () => {
        failure = code;
        const source = await setMessage(editor, counter, 'Olá {{agent.name}}');
        const before = newSends;
        const refreshPromise = page.waitForResponse(response => response.url().endsWith('/sms_preview') && response.request().method() === 'POST');
        await send.click();
        await editor.press('Control+Enter');
        const refresh = await refreshPromise;
        assert.equal(refresh.request().postDataJSON().content, source);
        await waitFor(async () => !(await send.isDisabled()), 'creation error released');
        assert.equal(newSends, before + 1);
      });
    }
    await test('New conversation preserves edits made before an earlier HTTP success', async () => {
      await context.unroute('**/conversations');
      await context.route('**/conversations', async route => {
        if (route.request().method() !== 'POST') return route.continue();
        const response = await route.fetch({ maxRedirects: 0 });
        await sleep(900);
        return route.fulfill({ response });
      });
      await setMessage(editor, counter, 'Primeiro texto fictício');
      const responsePromise = page.waitForResponse(response => new URL(response.url()).pathname.endsWith('/conversations') && response.request().method() === 'POST');
      await send.click();
      await clearEditor(editor);
      await editor.fill('Rascunho novo enquanto envia');
      const response = await responsePromise;
      assert.ok(response.status() >= 200 && response.status() < 300);
      await waitFor(async () => !(await send.isDisabled()), 'creation completed with a new draft');
      assert.equal(await popup.isVisible(), true);
      assert.ok((await editor.innerText()).includes('Rascunho novo enquanto envia'));
    });
    await test('New conversation clears only after actual isolated HTTP success', async () => {
      await context.unroute('**/conversations');
      await setMessage(editor, counter, 'Sucesso fictício sem envio ao provedor');
      const responsePromise = page.waitForResponse(response => new URL(response.url()).pathname.endsWith('/conversations') && response.request().method() === 'POST');
      await send.click();
      const response = await responsePromise;
      assert.ok(response.status() >= 200 && response.status() < 300);
      await popup.waitFor({ state: 'hidden' });
    });
    assert.deepEqual(errors, []);
  } catch (error) {
    results.push({ name: 'Browser suite', status: 'FAIL', error: error.stack });
    if (page) {
      await page.screenshot({ path: path.join(out, 'browser-failure.png'), fullPage: true }).catch(() => {});
      fs.writeFileSync(path.join(out, 'browser-failure-dom.txt'), await page.locator('body').innerText().catch(() => 'unavailable'));
    }
    throw error;
  } finally {
    fs.writeFileSync(path.join(out, 'browser-results.json'), JSON.stringify({ results, errors, runtime: await browser.version(), isolated: true, realSmsSent: 0 }, null, 2));
    fs.writeFileSync(path.join(out, 'browser-editor-actions.json'), JSON.stringify(editorActions, null, 2));
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
