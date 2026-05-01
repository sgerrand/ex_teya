# Changelog

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
