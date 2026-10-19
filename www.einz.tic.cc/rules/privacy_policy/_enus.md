# Einz - Privacy policy

🌐 [简体中文](./_zhcn.md)

🚀 [Download](https://github.com/faronear/einz/releases/tag/latest)

---

Last updated: 2026-10-19

## What we cannot see

Einz is an end-to-end encrypted app. Your messages, photos, videos, voice notes, and files are encrypted **on your device**, and the keys exist only on your device and your companion's. The server — including the people running it — **cannot decrypt** any content.

## What the server stores

To carry a message from one device to another, the server must keep:

- Encrypted message bodies and attachments (ciphertext);
- The metadata delivery requires: timestamps, sizes, the sender's entrance identifier, and sequence numbers;
- Entrance registration data (entrance identifiers and statuses), along with each member's display name and gender within a space.

The server does **not** store: message plaintext, your PIN, the shared passphrase, or any key material.

## What your device stores

All of your content lives in the app's database on your device, and a PIN is required every time you open the app. Deleting a space also erases that space's data from your device.

## What we don't do

- No ads, no user profiling, no data selling;
- No collection or analysis of your chat content (we can't, and we wouldn't);
- No third-party analytics SDKs.

## Data deletion

- Delete a space: erases that space's data from your device at the same time;
- Revoke an entrance: cuts off that device's access immediately;
- To delete data from the server, contact us (see below).

## Contact us

- Email: [einz@tic.cc](mailto:einz@tic.cc)
- Or file an issue on [GitHub](https://github.com/faronear/einz).
