# Einz - Leaving a group

🌐 [简体中文](./_zhcn.md)

🚀 [Download](https://github.com/faronear/einz/releases/tag/latest)

---

In a group space (three or more members), anyone can leave on their own. Here is what leaving means, and the usual questions.

## How to leave

Open the members sheet (tap the group name capsule in the top bar) and use the red **Leave group** item at the bottom. You will be asked to type the **group name** to confirm (plus your device PIN if you set one) — the same gate as "Destroy this entrance", so a stray tap can't do it.

## What happens when you leave

- **This group is erased from this device**: messages, attachments, credentials — all of it;
- **History stays on the other members' devices** — they can still read everything from before;
- **Your other devices** (the same identity's phone + tablet, etc.) **erase their local data automatically**, just like being revoked;
- The member count drops by one, and the freed slot can be filled by whoever the remaining members invite.

## FAQ

**Can I come back later?**
Yes, but a remaining member has to send you a **new invite** — you will join as a **new identity** (new name, new avatar). History before you left stays readable (new members can always read all of it).

**Can I leave a duo space?**
No. A duo space is a contract between two people: once an identity is in, it never leaves. The only way out is **Destroy this entrance** (menu → Advanced) — that retires this device's entrance only; your identity stays on the books, and the other person can pull you back in any time with "Re-invite".

**Does leaving invalidate the messages?**
No. Anyone who saved the Space Key and the ciphertext beforehand can still decrypt the history from before you left — that is an inherent boundary of end-to-end encryption. Leaving only stops the server from delivering new messages to your entrances, and deletes the key material on your devices.

**What if the last member leaves?**
The space freezes: the data stays on the server, but no member is left to send invites. Duo spaces don't have this problem (leaving isn't offered there).

**Why isn't the shared passphrase required?**
Leaving is "retiring myself" — the session on this device is proof of ownership (same tier as self-retire); the confirmation gate uses the **group name + device PIN**, factors only this device holds. The shared passphrase is a joining credential; it should not gain the power to exit your identity.

---

🚀 Something wrong? Report it on [GitHub](https://github.com/faronear/einz).
