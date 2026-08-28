// Ask Azure for a Graph token, as this container, and report what came back.
//
// Run inside the worker container, not on the host. The host having an identity
// and the container being able to use it are different claims, and only the
// second one matters — the worker is what provisions.
const IMDS =
  "http://169.254.169.254/metadata/identity/oauth2/token" +
  "?api-version=2018-02-01&resource=https%3A%2F%2Fgraph.microsoft.com";

const response = await fetch(IMDS, { headers: { Metadata: "true" } });
if (!response.ok) {
  console.log("TOKEN  no — " + response.status + " " + (await response.text()).slice(0, 200));
  process.exit(1);
}

const { access_token: token } = await response.json();
console.log("TOKEN  yes");

// The roles claim is the whole question. A token always arrives; a token with
// no roles is what a missing or unpropagated permission looks like, and it
// fails later as a 403 that names nothing.
const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64").toString());
const roles = claims.roles ?? [];
console.log("TENANT " + claims.tid);
console.log("ROLES  " + (roles.length ? roles.join(", ") : "NONE — the grant has not arrived yet"));

const graph = await fetch(
  "https://graph.microsoft.com/v1.0/users?$top=1&$select=id",
  { headers: { Authorization: "Bearer " + token } },
);
if (graph.ok) {
  console.log("GRAPH  yes — the directory answered");
} else {
  const body = await graph.text();
  console.log("GRAPH  no — " + graph.status + " " + body.slice(0, 300));
  process.exit(1);
}
