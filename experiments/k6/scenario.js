import exec from "k6/execution";
import http from "k6/http";
import {check, sleep} from "k6";
import {SharedArray} from "k6/data";

const model = __ENV.MODEL;
const warmupSeconds = positiveInt("WARMUP_SECONDS", 30);
const steadySeconds = positiveInt("STEADY_SECONDS", 120);
const cooldownSeconds = positiveInt("COOLDOWN_SECONDS", 30);
const vusPerTenant = positiveInt("VUS_PER_TENANT", 2);
const thinkTimeSeconds = nonNegativeNumber("THINK_TIME_SECONDS", 0.25);

const routes = JSON.parse(open(__ENV.ROUTES_FILE));
const credentials = new SharedArray("tenant credentials", () =>
  parseCredentials(open(__ENV.CREDENTIALS_FILE))
);

if (!model || routes.length === 0 || credentials.length === 0) {
  throw new Error("MODEL, ROUTES_FILE and CREDENTIALS_FILE must describe at least one tenant");
}

const routeByTenant = Object.fromEntries(routes.map((route) => [route.tenant, route]));
const usersByTenant = {};
for (const credential of credentials) {
  usersByTenant[credential.tenant] ||= [];
  usersByTenant[credential.tenant].push(credential);
}

const scenarios = {};
for (const [index, route] of routes.entries()) {
  if (!usersByTenant[route.tenant]?.length) {
    throw new Error(`No credentials configured for tenant ${route.tenant}`);
  }

  const suffix = `${String(index + 1).padStart(2, "0")}_${safeName(route.tenant)}`;
  const common = {
    exec: "tenantWorkload",
    env: {TENANT: route.tenant},
    gracefulStop: "5s",
  };

  scenarios[`warmup_${suffix}`] = {
    ...common,
    executor: "ramping-vus",
    startVUs: 0,
    stages: [{duration: `${warmupSeconds}s`, target: vusPerTenant}],
    tags: {model, tenant: route.tenant, phase: "warmup"},
  };
  scenarios[`steady_${suffix}`] = {
    ...common,
    executor: "constant-vus",
    vus: vusPerTenant,
    duration: `${steadySeconds}s`,
    startTime: `${warmupSeconds}s`,
    tags: {model, tenant: route.tenant, phase: "steady"},
  };
  scenarios[`cooldown_${suffix}`] = {
    ...common,
    executor: "ramping-vus",
    startVUs: vusPerTenant,
    stages: [{duration: `${cooldownSeconds}s`, target: 0}],
    startTime: `${warmupSeconds + steadySeconds}s`,
    tags: {model, tenant: route.tenant, phase: "cooldown"},
  };
}

export const options = {
  scenarios,
  discardResponseBodies: false,
  summaryTrendStats: ["avg", "min", "med", "max", "p(50)", "p(95)", "p(99)"],
  thresholds: {
    "checks{phase:steady}": [{threshold: "rate>0.98", abortOnFail: false}],
    "http_req_failed{phase:steady}": [{threshold: "rate<0.02", abortOnFail: false}],
    "http_req_duration{phase:steady}": [{threshold: "p(99)<2000", abortOnFail: false}],
    "http_reqs{phase:steady}": [{threshold: "count>0", abortOnFail: false}],
  },
};

export function tenantWorkload() {
  const tenant = __ENV.TENANT;
  const route = routeByTenant[tenant];
  const users = usersByTenant[tenant];
  const user = users[exec.scenario.iterationInTest % users.length];
  const headers = routeHeaders(route);

  const loginResponse = http.post(
    apiUrl(route, "/user/login"),
    JSON.stringify({email: user.email, password: user.password}),
    requestParams(
      {...headers, "Content-Type": "application/json"},
      "authenticate",
      "POST /api/user/login"
    )
  );
  const loginOk = check(loginResponse, {
    "login succeeded": (response) => response.status === 200,
  });
  if (!loginOk) {
    sleep(thinkTimeSeconds);
    return;
  }

  const loginBody = parseJson(loginResponse);
  const token = loginBody?.bearerToken;
  if (!token) {
    check(null, {"login returned bearer token": () => false});
    sleep(thinkTimeSeconds);
    return;
  }

  const authorization = token.startsWith("Bearer ") ? token : `Bearer ${token}`;
  const authHeaders = {...headers, Authorization: authorization};
  const projectsResponse = http.get(
    apiUrl(route, "/project/all"),
    requestParams(authHeaders, "read", "GET /api/project/all")
  );
  const projectsOk = check(projectsResponse, {
    "projects read succeeded": (response) => response.status === 200,
  });
  if (!projectsOk) {
    sleep(thinkTimeSeconds);
    return;
  }

  const projects = parseJson(projectsResponse);
  if (!Array.isArray(projects) || projects.length === 0) {
    sleep(thinkTimeSeconds);
    return;
  }

  const project = projects[Math.floor(Math.random() * projects.length)];
  const operationRoll = Math.random();
  if (operationRoll < 0.6) {
    readIssues(route, authHeaders, project);
  } else if (operationRoll < 0.8) {
    createIssue(route, authHeaders, project, tenant);
  } else {
    updateIssue(route, authHeaders, project, tenant);
  }

  sleep(thinkTimeSeconds);
}

function readIssues(route, headers, project) {
  const response = listIssues(route, headers, project, "read");
  check(response, {"issues read succeeded": (item) => item.status === 200});
}

function createIssue(route, headers, project, tenant) {
  const response = http.post(
    apiUrl(route, "/issue"),
    JSON.stringify({
      projectKey: project.projectKey,
      issueStatus: "Backlog",
      summary: `Experiment ${tenant} ${Date.now()}-${exec.vu.idInTest}`,
      details: "Created by the reproducible observability experiment",
      sprintId: null,
    }),
    requestParams(
      {...headers, "Content-Type": "application/json"},
      "write",
      "POST /api/issue"
    )
  );
  check(response, {"issue create succeeded": (item) => item.status === 201});
}

function updateIssue(route, headers, project, tenant) {
  const listResponse = listIssues(route, headers, project, "write-lookup");
  if (listResponse.status !== 200) {
    check(listResponse, {"issues for update read succeeded": () => false});
    return;
  }

  const issues = parseJson(listResponse);
  if (!Array.isArray(issues) || issues.length === 0) {
    createIssue(route, headers, project, tenant);
    return;
  }

  const issue = issues[Math.floor(Math.random() * issues.length)];
  const response = http.patch(
    `${apiUrl(route, `/issue/${issue.issueId}`)}?projectKey=${encodeURIComponent(project.projectKey)}`,
    JSON.stringify({
      issueStatus: "In Progress",
      summary: `Experiment update ${tenant} ${Date.now()}-${exec.vu.idInTest}`,
    }),
    requestParams(
      {...headers, "Content-Type": "application/json"},
      "write",
      "PATCH /api/issue/:issueId"
    )
  );
  check(response, {"issue update succeeded": (item) => item.status === 200});
}

function listIssues(route, headers, project, operation) {
  return http.get(
    `${apiUrl(route, `/issue/project/${project.projectKey}`)}?limit=20&offset=0`,
    requestParams(headers, operation, "GET /api/issue/project/:projectKey")
  );
}

function apiUrl(route, path) {
  return `${route.baseUrl}${route.apiPrefix}${path}`;
}

function routeHeaders(route) {
  const headers = {};
  if (route.tenantHeader) {
    headers.tenant = route.tenant;
  }
  return headers;
}

function requestParams(headers, operation, endpoint) {
  return {
    headers,
    tags: {
      operation,
      endpoint,
    },
  };
}

function parseJson(response) {
  try {
    return response.json();
  } catch (_) {
    return null;
  }
}

function parseCredentials(csv) {
  return csv
    .trim()
    .split(/\r?\n/)
    .slice(1)
    .filter(Boolean)
    .map((line) => {
      const [tenant, email, password] = line.split(",");
      return {tenant, email, password};
    });
}

function safeName(value) {
  return value.toLowerCase().replace(/[^a-z0-9_]+/g, "_");
}

function positiveInt(name, fallback) {
  const value = Number.parseInt(__ENV[name] || `${fallback}`, 10);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

function nonNegativeNumber(name, fallback) {
  const value = Number.parseFloat(__ENV[name] || `${fallback}`);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`${name} must be a non-negative number`);
  }
  return value;
}

export function handleSummary(data) {
  const stableDuration = data.metrics["http_req_duration{phase:steady}"]?.values || {};
  const stableFailures = data.metrics["http_req_failed{phase:steady}"]?.values || {};
  const stableRequests = data.metrics["http_reqs{phase:steady}"]?.values || {};
  const stableRequestRate = (stableRequests.count || 0) / steadySeconds;
  const summary = [
    "",
    `model=${model}`,
    `tenants=${routes.length}`,
    `steady requests=${stableRequests.count ?? 0}`,
    `steady request rate=${stableRequestRate}`,
    `steady error rate=${stableFailures.rate ?? 0}`,
    `steady latency p50=${stableDuration["p(50)"] ?? "n/a"} ms`,
    `steady latency p95=${stableDuration["p(95)"] ?? "n/a"} ms`,
    `steady latency p99=${stableDuration["p(99)"] ?? "n/a"} ms`,
    "",
  ].join("\n");

  return {
    stdout: summary,
    [__ENV.K6_SUMMARY_PATH]: JSON.stringify(data, null, 2),
  };
}
