// F5.3: the support page (App Store "Support URL"), served at /support.
import { esc } from "./render.js";
import { CONTACT } from "./privacy.js";

const QA = [
  ["How do I add food?",
    "Tap the camera on the Pantry tab and take a photo of a shelf, or tap + to search the food list and add items yourself. Check the list after a scan and fix anything that's wrong before saving."],
  ["Why is an expiry date wrong?",
    "Dates are estimates based on the food and where it's kept. Tap an item to change its date; you can also choose to always use your own date for that food."],
  ["How do I get recipe ideas?",
    "On the Recipes tab, tap Get recipe ideas. Recipes use what expires first and leave out the allergies and diets in Settings → Food preferences."],
  ["How do I cancel or manage my subscription?",
    "Open your iPhone's Settings → your name → Subscriptions, then choose Spoil Not. Cancel at least 24 hours before the renewal date. Refunds are handled by Apple at reportaproblem.apple.com."],
  ["I changed phones and lost my subscription.",
    "In the app, open Settings → Subscription and tap Restore purchases while signed in to the same Apple ID."],
  ["I'm not getting expiry reminders.",
    "Check Settings → Expiry reminders in the app, and that notifications are allowed for Spoil Not in your iPhone's Settings → Notifications."],
  ["How do I delete my data?",
    "In the app, open Settings → Delete account. Everything is deleted straight away and shared links stop working. Deleting the app alone doesn't delete your account. A subscription isn't cancelled by deleting your account: cancel it in Settings → your name → Subscriptions."],
];

export function supportBody() {
  const items = QA.map(([q, a]) => `<h2>${esc(q)}</h2><p>${esc(a)}</p>`).join("\n");
  return `
<h1>Spoil Not support</h1>
<p class="desc">Questions, problems or ideas? Email <a href="mailto:${esc(CONTACT)}">${esc(CONTACT)}</a> and we'll get back to you.</p>
${items}
<footer>
  <p><a href="/privacy">Privacy policy</a></p>
</footer>`;
}
