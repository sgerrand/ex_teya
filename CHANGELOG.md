# Changelog

## [1.0.0](https://github.com/sgerrand/ex_teya/compare/v0.4.3...v1.0.0) (2026-09-26)


### ⚠ BREAKING CHANGES

* without :token_url set, tokens are now fetched from https://id.teya.com/oauth/v2/oauth-token instead of https://identity.teya.com/connect/token. To keep the old endpoint, set config :teya, token_url: "https://identity.teya.com/connect/token".
* **auth:** a failed token fetch returns {:error, %Teya.Error{}} rather than {:error, %Req.Response{}}. Transport failures still return the underlying Req exception.
* **error:** a failed token fetch returns {:error, %Teya.Error{}} rather than {:error, %Req.Response{}}. Transport failures still return the underlying Req exception.
* **webhook:** verify/3 and parse/3 no longer accept a PEM or Base64 key. Read it with Teya.Webhook.decode_key/1 and pass the result.
* **poslink:** Refund.create/2 now takes transaction_id (the original payment's gateway_payment_id) and amount instead of store_id and payment_request_id. Refund statuses are SUCCESS, FAILURE or PENDING. Payment.create/2 requires transaction_type and merchant_reference. Payment.list/1 requires the store_id query param. Payment.get/2 accepts only a :timeout option and can return {:error, :timeout} or

### Features

* add a staging environment and use the token URL Teya documents ([#48](https://github.com/sgerrand/ex_teya/issues/48)) ([da3a4d8](https://github.com/sgerrand/ex_teya/commit/da3a4d802131cb55fc740b3ee99825ea888046c5))
* add MOTO payments, POSLink receipt text, store configs and ePOS registration ([#45](https://github.com/sgerrand/ex_teya/issues/45)) ([5e90476](https://github.com/sgerrand/ex_teya/commit/5e904760934d65a0ca6ff245e267c4dc79c148b1))
* **error:** richer errors and a library user agent ([#40](https://github.com/sgerrand/ex_teya/issues/40)) ([7a157d5](https://github.com/sgerrand/ex_teya/commit/7a157d5cdd367d1ab398c93ebd6e0d65c27a4e5b))
* opt-in retries for POSTs that are safe to repeat ([#47](https://github.com/sgerrand/ex_teya/issues/47)) ([c7c9781](https://github.com/sgerrand/ex_teya/commit/c7c9781477a831c193449e8281b9900941d9f39e))
* **webhook:** check the signature on an incoming webhook ([#43](https://github.com/sgerrand/ex_teya/issues/43)) ([6f58e07](https://github.com/sgerrand/ex_teya/commit/6f58e0787c6623f3bded23966419a90e16829407))


### Bug Fixes

* encode every id put into a request path ([#46](https://github.com/sgerrand/ex_teya/issues/46)) ([ad12c33](https://github.com/sgerrand/ex_teya/commit/ad12c33a78f0f096486a96ef1c55b7e15ba4691d))
* **poslink:** move to current POSLink payment and refund endpoints ([#37](https://github.com/sgerrand/ex_teya/issues/37)) ([b61ca85](https://github.com/sgerrand/ex_teya/commit/b61ca852529b603f20d9e397c58a9fce2ca4ff52))
* **poslink:** read the snapshot in get/2 outside the caller's mailbox ([#41](https://github.com/sgerrand/ex_teya/issues/41)) ([272b472](https://github.com/sgerrand/ex_teya/commit/272b47280830b107a5f74c96fdb5d01f7a3b73bb))
* **sse:** cut an oversized error chunk instead of copying it whole ([#42](https://github.com/sgerrand/ex_teya/issues/42)) ([b066431](https://github.com/sgerrand/ex_teya/commit/b06643178a0cd484482c19601b50e93f654e5884))
* **sse:** keep the error body on failed stream requests ([#39](https://github.com/sgerrand/ex_teya/issues/39)) ([ee0c912](https://github.com/sgerrand/ex_teya/commit/ee0c912233bde01c9ee7e273d4227d157787f565))


### Code Refactoring

* **auth:** fetch tokens in a task and let waiting callers share it ([#44](https://github.com/sgerrand/ex_teya/issues/44)) ([ba6ee07](https://github.com/sgerrand/ex_teya/commit/ba6ee07b074321da91b7b44ded9109ac9ecc2ca2))

## [0.4.3](https://github.com/sgerrand/ex_teya/compare/v0.4.2...v0.4.3) (2026-09-10)


### Bug Fixes

* **deps:** bump req from 0.7.1 to 0.7.2 ([#30](https://github.com/sgerrand/ex_teya/issues/30)) ([a57b467](https://github.com/sgerrand/ex_teya/commit/a57b467ab766c39e36f51e6d96ab09615fd5240e))
* **deps:** bump req_server_sent_events from 0.2.2 to 0.2.3 ([#34](https://github.com/sgerrand/ex_teya/issues/34)) ([07093df](https://github.com/sgerrand/ex_teya/commit/07093df0a7fe7b5ddca9cc05e2db7c6a76fcbf06))

## [0.4.2](https://github.com/sgerrand/ex_teya/compare/v0.4.1...v0.4.2) (2026-08-06)


### Bug Fixes

* **deps:** bump req_server_sent_events from 0.2.1 to 0.2.2 ([#25](https://github.com/sgerrand/ex_teya/issues/25)) ([4f901e8](https://github.com/sgerrand/ex_teya/commit/4f901e850384893071fd6aa68f08c0c245130837))

## [0.4.1](https://github.com/sgerrand/ex_teya/compare/v0.4.0...v0.4.1) (2026-07-18)


### Bug Fixes

* **deps:** bump jason from 1.4.4 to 1.4.5 ([#11](https://github.com/sgerrand/ex_teya/issues/11)) ([f6695de](https://github.com/sgerrand/ex_teya/commit/f6695de567efcf1b33d8e8713e540d0f8fa126f6))
* **deps:** bump req from 0.5.17 to 0.5.18 ([#13](https://github.com/sgerrand/ex_teya/issues/13)) ([2ced175](https://github.com/sgerrand/ex_teya/commit/2ced1754af8dfce613f796df651e94beb4603ff8))
* **deps:** bump req from 0.5.18 to 0.6.1 ([#18](https://github.com/sgerrand/ex_teya/issues/18)) ([eff3b6c](https://github.com/sgerrand/ex_teya/commit/eff3b6ca3f2e167806f35500ec769eed472debe4))
* **deps:** bump req_server_sent_events from 0.2.0 to 0.2.1 ([#22](https://github.com/sgerrand/ex_teya/issues/22)) ([26713b6](https://github.com/sgerrand/ex_teya/commit/26713b641d58e1240aa5ec07c139463ac5981e56))

## [0.4.0](https://github.com/sgerrand/ex_teya/compare/v0.3.0...v0.4.0) (2026-05-02)


### Features

* add Teya.DCC for unauthenticated currency conversion quotes ([9bc0b64](https://github.com/sgerrand/ex_teya/commit/9bc0b648bd1db504bcf1768b76ec3e6c38b79638))

## [0.3.0](https://github.com/sgerrand/ex_teya/compare/v0.2.0...v0.3.0) (2026-05-01)


### Features

* add Teya.CardPresent for card-present transactions ([bcce7f9](https://github.com/sgerrand/ex_teya/commit/bcce7f9a9e7d32e6a75c8983bc429e334938fa87))
* add Teya.Reversal for voiding unsettled transactions ([b326668](https://github.com/sgerrand/ex_teya/commit/b326668935470d4952d08d77c5ce4ad24a7cf4ac))

## [0.2.0](https://github.com/sgerrand/ex_teya/compare/v0.1.0...v0.2.0) (2026-05-01)


### Features

* **auth:** add structured logging and exponential backoff on retry ([ae1c1e0](https://github.com/sgerrand/ex_teya/commit/ae1c1e072914065f27aa7de4650a129d0fabb3fe))
* **client:** add default 30s HTTP receive_timeout ([1eecc5e](https://github.com/sgerrand/ex_teya/commit/1eecc5e37becb583abadee3f3251e350901adaf7))
* **config:** validate required fields at startup ([86242de](https://github.com/sgerrand/ex_teya/commit/86242de84ae28c50ebda1537033c4fa69389227e))
* **poslink:** add Payment.get/2 for single payment request lookup ([29b33cf](https://github.com/sgerrand/ex_teya/commit/29b33cfa019ae7f47a81a081f6f5fe060278217a))
* **poslink:** add SSE frame parser ([64141b0](https://github.com/sgerrand/ex_teya/commit/64141b0db14a8783cb24fa68c489420c03368cec))
* **poslink:** add SSE streaming subscriptions via Task.Supervisor ([ebc7f07](https://github.com/sgerrand/ex_teya/commit/ebc7f0773a337097267aa47c3343d2bc722f5361))
* **poslink:** add store, payment, refund, and receipt modules ([67cf504](https://github.com/sgerrand/ex_teya/commit/67cf50444cb63e31b61ec0c1488336045db0e047))


### Bug Fixes

* **build:** add missing markdownlint config file ([18a9702](https://github.com/sgerrand/ex_teya/commit/18a9702c0357dfbe4fd6542f15e6074d891ff072))
* **docs:** specify language in markdown code block ([71884bc](https://github.com/sgerrand/ex_teya/commit/71884bcb375cdcd3f233f6b2e3ff01e81db0edbc))
* **error:** preserve raw body in fallback error responses ([f50e5e8](https://github.com/sgerrand/ex_teya/commit/f50e5e8825ae66cc3aeaca06051e7ee39b9efe97))
* **test:** reset Auth GenServer state between APICase tests ([a2b3d60](https://github.com/sgerrand/ex_teya/commit/a2b3d6020f222602e2915f400f99a5dc7cbd40cb))
