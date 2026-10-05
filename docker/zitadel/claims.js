// Complement-token action, scoped to the dedicated Fred project.
function fredClaims(ctx, api) {
  var user = ctx.v1.getUser();
  var services = FRED_SERVICE_CLIENTS;
  var applicationClient = ctx.v1.application.getClientId();
  // Flows can cover an entire organization. Leave unrelated apps untouched.
  if (applicationClient !== "FRED_SPA_CLIENT_ID" && !services[user.id]) { return; }
  var roles = [];
  var grants = ctx.v1.user.grants;
  if (grants) {
    grants.grants.forEach(function (grant) {
      if (grant.projectId === "FRED_PROJECT_ID") {
        grant.roles.forEach(function (role) { roles.push(role); });
      }
    });
  }
  api.v1.claims.setClaim("roles", roles);
  api.v1.claims.setClaim("client_id", services[user.id] || applicationClient);
  api.v1.claims.setClaim("preferred_username", user.preferredLoginName || user.username);
  if (user.human) {
    api.v1.claims.setClaim("email", user.human.email);
    api.v1.claims.setClaim("given_name", user.human.firstName);
    api.v1.claims.setClaim("family_name", user.human.lastName);
  }
}
