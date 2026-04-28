import Config

config :teya,
  client_id: "test_client_id",
  client_secret: "test_client_secret",
  token_url: "https://identity.teya.test/connect/token",
  base_url: "https://api.teya.test",
  scopes: ["checkout/sessions/create", "checkout/sessions/id/get"],
  # Auth uses a separate stub name so the token endpoint can be stubbed
  # independently of the API endpoints.
  auth_req_options: [plug: {Req.Test, Teya.Auth}],
  req_options: [plug: {Req.Test, Teya.Client}]
