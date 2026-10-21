const config = window.__FAUCET_CONFIG__ || {};

const walletInput = document.getElementById('wallet-address');
const questionEl = document.getElementById('challenge-question');
const answerInput = document.getElementById('challenge-answer');
const challengeButton = document.getElementById('challenge-button');
const claimButton = document.getElementById('claim-button');
const statusEl = document.getElementById('status');
const receiptEl = document.getElementById('receipt');
const receiptHashEl = document.getElementById('receipt-hash');
const receiptAmountEl = document.getElementById('receipt-amount');
const receiptBalanceEl = document.getElementById('receipt-balance');
const receiptExplorerEl = document.getElementById('receipt-explorer');
const explorerLinkEl = document.getElementById('explorer-link');
const discordLinkEl = document.getElementById('discord-link');
const discordCopyEl = document.getElementById('discord-copy');
const opsCopyEl = document.getElementById('ops-copy');
const opsCore4El = document.getElementById('ops-core4');
const opsRedisEl = document.getElementById('ops-redis');
const opsDiscordEl = document.getElementById('ops-discord');
const copyButton = document.getElementById('copy-receipt');

let activeChallengeId = '';
let activeChallengeQuestion = '';
let lastReceipt = null;

function setStatus(kind, text) {
  statusEl.className = `status ${kind}`;
  statusEl.textContent = text;
}

function setReceiptVisible(visible) {
  receiptEl.classList.toggle('hidden', !visible);
}

function syncDiscordLink() {
  const gateUrl = config.discordOauthUrl || config.discordInviteUrl || '';
  if (gateUrl) {
    discordLinkEl.href = gateUrl;
    discordLinkEl.textContent = config.discordOauthUrl ? 'Connect Discord' : 'Join Discord';
    discordCopyEl.textContent = config.discordOauthUrl
      ? 'Authenticate with Discord before you claim.'
      : 'Discord invite is available if you want to join the operator community first.';
  } else {
    discordLinkEl.removeAttribute('href');
    discordLinkEl.textContent = 'Discord unavailable';
    discordCopyEl.textContent = 'No Discord gate is configured for this faucet container.';
  }
}

function syncOpsCard() {
  const core4Target = config.core4ApiUrl || 'http://wrfcoin-node:8556';
  const redisState = config.redisConfigured ? 'Redis throttle wired' : 'Redis throttle unavailable';
  const discordState = config.discordClientId ? 'Discord OAuth configured' : 'Discord invite fallback';

  opsCore4El.textContent = core4Target;
  opsRedisEl.textContent = redisState;
  opsDiscordEl.textContent = discordState;
  opsCopyEl.textContent = `This faucet UI proxies ${core4Target}, keeps the claim surface captcha-backed, and exposes the rate-limit and Discord gate wiring used by the operator flow.`;
}

function syncExplorerLink(txHash = '') {
  if (!config.explorerUrl) {
    return;
  }

  const target = new URL(config.explorerUrl, window.location.origin);
  if (txHash) {
    target.searchParams.set('tx', txHash);
  }

  explorerLinkEl.href = target.toString();
  receiptExplorerEl.href = target.toString();
}

function validateWalletAddress(value) {
  return /^0x[0-9a-fA-F]{40}$/.test(value);
}

async function loadChallenge() {
  setStatus('neutral', 'Requesting a fresh captcha challenge...');
  claimButton.disabled = true;
  receiptEl.classList.add('hidden');

  const response = await fetch('/api/onboarding/faucet/challenge', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });

  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload?.error?.message || 'Could not load challenge');
  }

  activeChallengeId = payload.challengeId;
  activeChallengeQuestion = payload.question;
  questionEl.textContent = activeChallengeQuestion;
  claimButton.disabled = false;
  answerInput.value = '';
  answerInput.focus();
  setStatus('success', 'Challenge ready. Solve it and drip the faucet.');
}

async function claimTokens() {
  if (!activeChallengeId) {
    await loadChallenge();
    return;
  }

  const walletAddress = walletInput.value.trim();
  const answer = answerInput.value.trim();

  if (!validateWalletAddress(walletAddress)) {
    setStatus('error', 'Wallet address must be a 0x-prefixed 40-character hex string.');
    walletInput.focus();
    return;
  }

  if (!answer) {
    setStatus('error', 'Enter the captcha answer before claiming.');
    answerInput.focus();
    return;
  }

  setStatus('neutral', 'Submitting claim...');
  claimButton.disabled = true;

  const response = await fetch('/api/onboarding/faucet/claim', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      walletAddress,
      challengeId: activeChallengeId,
      answer,
    }),
  });

  const payload = await response.json();
  if (!response.ok) {
    const code = payload?.error?.code || 'CLAIM_FAILED';
    const message = payload?.error?.message || 'Claim failed';
    setStatus('error', `${code}: ${message}`);
    claimButton.disabled = false;
    return;
  }

  lastReceipt = payload;
  receiptHashEl.textContent = payload.txHash;
  receiptAmountEl.textContent = `${payload.amount} WRF`;
  receiptBalanceEl.textContent = `${payload.balance} WRF`;
  syncExplorerLink(payload.txHash);
  setReceiptVisible(true);
  setStatus('success', `Claim approved. ${payload.amount} WRF sent to ${walletAddress}.`);

  activeChallengeId = '';
  activeChallengeQuestion = '';
  questionEl.textContent = 'Press the button to begin.';
  claimButton.disabled = true;
  answerInput.value = '';
}

challengeButton.addEventListener('click', () => {
  loadChallenge().catch((error) => {
    setStatus('error', error.message || 'Unable to create challenge.');
    claimButton.disabled = true;
  });
});

claimButton.addEventListener('click', () => {
  claimTokens().catch((error) => {
    setStatus('error', error.message || 'Claim flow failed.');
    claimButton.disabled = false;
  });
});

copyButton.addEventListener('click', async () => {
  if (!lastReceipt) {
    return;
  }

  const receiptText = [
    `WRFCoin faucet receipt`,
    `txHash: ${lastReceipt.txHash}`,
    `amount: ${lastReceipt.amount} WRF`,
    `balance: ${lastReceipt.balance} WRF`,
    `explorer: ${receiptExplorerEl.href}`,
  ].join('\n');

  try {
    await navigator.clipboard.writeText(receiptText);
    setStatus('success', 'Receipt copied to clipboard.');
  } catch (_error) {
    setStatus('error', 'Clipboard copy failed in this browser.');
  }
});

walletInput.addEventListener('input', () => {
  if (!walletInput.value.trim()) {
    claimButton.disabled = true;
  }
});

questionEl.textContent = 'Press the button to begin.';
syncDiscordLink();
syncOpsCard();
syncExplorerLink();
setStatus('neutral', 'Waiting for the first challenge.');
