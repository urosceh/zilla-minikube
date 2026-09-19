import exec from "k6/execution";
import http from "k6/http";
import {check, sleep} from "k6";
import {SharedArray} from "k6/data";

const model = __ENV.MODEL;
const warmupSeconds = positiveInt("WARMUP_SECONDS", 60);
const steadySeconds = positiveInt("STEADY_SECONDS", 180);
const cooldownSeconds = positiveInt("COOLDOWN_SECONDS", 30);
const vusPerTenant = positiveInt("VUS_PER_TENANT", 10);
const thinkTimeMinSeconds = nonNegativeNumber("THINK_TIME_MIN_SECONDS", 2);
const thinkTimeMaxSeconds = nonNegativeNumber("THINK_TIME_MAX_SECONDS", 4);

if (thinkTimeMinSeconds > thinkTimeMaxSeconds) {
  throw new Error("THINK_TIME_MIN_SECONDS must be less than or equal to THINK_TIME_MAX_SECONDS");
}

const routes = JSON.parse(open(__ENV.ROUTES_FILE));
const credentials = new SharedArray("tenant credentials", () =>
  parseCredentials(open(__ENV.CREDENTIALS_FILE))
);

if (!model || routes.length === 0 || credentials.length === 0) {
  throw new Error("MODEL, ROUTES_FILE and CREDENTIALS_FILE must describe at least one tenant");
}

const routeByTenant = Object.fromEntries(routes.map((route) => [route.tenant, route]));
const usersByTenant = {};
const sessionsByTenant = {};
for (const credential of credentials) {
  usersByTenant[credential.tenant] ||= [];
  usersByTenant[credential.tenant].push(credential);
}

const scenarios = {};
for (const [index, route] of routes.entries()) {
  const userCount = usersByTenant[route.tenant]?.length || 0;
  if (userCount < vusPerTenant) {
    throw new Error(
      `Tenant ${route.tenant} has ${userCount} credential(s), but ${vusPerTenant} VUs require at least that many`
    );
  }

  const suffix = `${String(index + 1).padStart(2, "0")}_${safeName(route.tenant)}`;
  const rampSeconds = Math.max(1, Math.floor(warmupSeconds / 2));
  const warmSeconds = warmupSeconds - rampSeconds;
  const stages = [{duration: `${rampSeconds}s`, target: vusPerTenant}];
  if (warmSeconds > 0) {
    stages.push({duration: `${warmSeconds}s`, target: vusPerTenant});
  }
  stages.push(
    {duration: `${steadySeconds}s`, target: vusPerTenant},
    {duration: `${cooldownSeconds}s`, target: 0}
  );

  scenarios[`workload_${suffix}`] = {
    exec: "tenantWorkload",
    env: {TENANT: route.tenant},
    executor: "ramping-vus",
    startVUs: 0,
    stages,
    gracefulRampDown: "0s",
    gracefulStop: "5s",
    tags: {model, tenant: route.tenant},
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
  exec.vu.metrics.tags.phase = currentPhase();

  const session = sessionForVu(route, users);
  if (!session) {
    think();
    return;
  }

  let authHeaders = authenticatedHeaders(route, session);
  let projectsResponse = http.get(
    apiUrl(route, "/project/all"),
    requestParams(authHeaders, "read", "GET /api/project/all")
  );
  if (projectsResponse.status === 401) {
    const refreshedAuthorization = authenticate(route, session.user);
    if (!refreshedAuthorization) {
      think();
      return;
    }
    session.authorization = refreshedAuthorization;
    authHeaders = authenticatedHeaders(route, session);
    projectsResponse = http.get(
      apiUrl(route, "/project/all"),
      requestParams(authHeaders, "read", "GET /api/project/all")
    );
  }
  const projectsOk = check(projectsResponse, {
    "projects read succeeded": (response) => response.status === 200,
  });
  if (!projectsOk) {
    think();
    return;
  }

  const projects = parseJson(projectsResponse);
  if (!Array.isArray(projects) || projects.length === 0) {
    think();
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

  think();
}

function currentPhase() {
  const elapsedSeconds = (Date.now() - exec.scenario.startTime) / 1000;
  if (elapsedSeconds < warmupSeconds) {
    return "warmup";
  }
  if (elapsedSeconds < warmupSeconds + steadySeconds) {
    return "steady";
  }
  return "cooldown";
}

function sessionForVu(route, users) {
  if (sessionsByTenant[route.tenant]) {
    return sessionsByTenant[route.tenant];
  }

  const user = users[(exec.vu.idInTest - 1) % users.length];
  const authorization = authenticate(route, user);
  if (!authorization) {
    return null;
  }

  sessionsByTenant[route.tenant] = {user, authorization};
  return sessionsByTenant[route.tenant];
}

function authenticate(route, user) {
  const response = http.post(
    apiUrl(route, "/user/login"),
    JSON.stringify({email: user.email, password: user.password}),
    requestParams(
      {...routeHeaders(route), "Content-Type": "application/json"},
      "authenticate",
      "POST /api/user/login"
    )
  );
  const loginOk = check(response, {
    "login succeeded": (item) => item.status === 200,
  });
  if (!loginOk) {
    return null;
  }

  const token = parseJson(response)?.bearerToken;
  const tokenOk = check(token, {
    "login returned bearer token": (value) => typeof value === "string" && value.length > 0,
  });
  if (!tokenOk) {
    return null;
  }

  return token.startsWith("Bearer ") ? token : `Bearer ${token}`;
}

function authenticatedHeaders(route, session) {
  return {...routeHeaders(route), Authorization: session.authorization};
}

function think() {
  const duration =
    thinkTimeMinSeconds + Math.random() * (thinkTimeMaxSeconds - thinkTimeMinSeconds);
  sleep(duration);
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
    `VUs per tenant=${vusPerTenant}`,
    `think time=${thinkTimeMinSeconds}-${thinkTimeMaxSeconds} s`,
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
