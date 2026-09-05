import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { SharedArray } from 'k6/data';
import http from 'k6/http';

// Env from runner
const SCRIPT_DIR = __ENV.SCRIPT_DIR;
const BASE_URL = __ENV.BASE_URL || `http://localhost:3000`;
const TENANTS_CSV = __ENV.TENANTS_CSV || '';
const PROJECTS_COUNT = Number(__ENV.PROJECTS_COUNT || 10);
const USERS_COUNT = Number(__ENV.USERS_COUNT || 50);

if (!TENANTS_CSV) {
  throw new Error('TENANTS_CSV environment variable is required (comma-separated)');
}

const TENANTS = TENANTS_CSV.split(',').map((t) => t.trim()).filter((t) => !!t);

// Per-tenant shared users (must be created in init context)
const tenantUsersMap = Object.fromEntries(
  TENANTS.map((tenant) => [
    tenant,
    new SharedArray(`users_${tenant}`, function () {
      const csvData = open(`${SCRIPT_DIR}/passwords/${tenant}/${tenant}.csv`);
      const lines = csvData.split('\n');
      const users = [];
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line) {
          const [userId, email, password] = line.split(',');
          users.push({ userId, email, password });
        }
      }
      return users;
    }),
  ])
);

// Linear scenario across all tenants
const RAMPUP_VUS = 30;
const RAMPUP_DURATION = '3s';
const STEADY_DURATION = '10s';
const RAMPDOWN_DURATION = '30s';

export const options = {
  stages: [
    { duration: RAMPUP_DURATION, target: RAMPUP_VUS },
    { duration: STEADY_DURATION, target: RAMPUP_VUS },
    { duration: RAMPDOWN_DURATION, target: 0 },
  ],
  thresholds: {
    'http_req_duration{phase:test}': [
      { threshold: 'p(95)<300', abortOnFail: false },
      { threshold: 'p(99)<500', abortOnFail: false },
    ],
    'http_req_duration{operation:login}': [
      { threshold: 'p(95)<1000', abortOnFail: false },
    ],
    'http_req_duration{operation:getProjects}': [
      { threshold: 'p(95)<1000', abortOnFail: false },
    ],
    'http_req_duration{operation:createIssue}': [
      { threshold: 'p(95)<1000', abortOnFail: false },
    ],
    'http_req_duration{operation:listIssues}': [
      { threshold: 'p(95)<1000', abortOnFail: false },
    ],
    'http_req_duration{operation:updateIssue}': [
      { threshold: 'p(95)<1000', abortOnFail: false },
    ],
    http_req_failed: ['rate<0.01'],
  },
  setupTimeout: '3m',
  gracefulRampDown: '3s',
};

// Global per-tenant state containers
const adminTokens = {};
const projectsMap = {};
const sprintMap = {};
const userTokenCache = {};

export function setup() {
  // For each tenant, perform setup similar to single-tenant script
  for (const tenant of TENANTS) {
    const ADMIN_EMAIL = `admin@${tenant}.dne.com`;
    const ADMIN_PASSWORD = 'admin123!';
    const users = tenantUsersMap[tenant];

    const adminLoginResponse = http.post(
      `${BASE_URL}/api/user/login`,
      JSON.stringify({ email: ADMIN_EMAIL, password: ADMIN_PASSWORD }),
      { headers: { 'Content-Type': 'application/json', tenant }, tags: { phase: 'setup' } }
    );

    if (adminLoginResponse.status !== 200) {
      throw new Error(`[${tenant}] Admin login failed: ${adminLoginResponse.body}`);
    }

    const adminData = JSON.parse(adminLoginResponse.body);
    adminTokens[tenant] = adminData.adminBearerToken;

    const projects = [];
    for (let i = 0; i < PROJECTS_COUNT; i++) {
      const managerIdx = Math.floor(i / 2) % users.length;
      const manager = users[managerIdx];
      const projectName = `Batch-Project-${i}-${randomString(4)}`;
      const projectKey = `BCH${i}`;

      const projectResponse = http.post(
        `${BASE_URL}/api/project`,
        JSON.stringify({ projectName, projectKey, managerId: manager.userId }),
        { headers: { 'Content-Type': 'application/json', Authorization: `${adminTokens[tenant]}`, tenant }, tags: { phase: 'setup' } }
      );

      if (projectResponse && projectResponse.status === 201) {
        projects.push(JSON.parse(projectResponse.body));
      } else {
        throw new Error(`[${tenant}] Project creation failed`);
      }
    }
    projectsMap[tenant] = projects;

    // Sprints per project (5 each)
    const tenantSprintMap = {};
    for (const project of projects) {
      const managerIdx = users.findIndex((u) => u.userId === project.managerId);
      if (managerIdx === -1) {
        throw new Error(`[${tenant}] Manager not found for project ${project.projectKey}`);
      }

      const loginResponse = http.post(
        `${BASE_URL}/api/user/login`,
        JSON.stringify({ email: users[managerIdx].email, password: users[managerIdx].password }),
        { headers: { 'Content-Type': 'application/json', tenant }, tags: { phase: 'setup' } }
      );
      if (loginResponse.status !== 200) {
        throw new Error(`[${tenant}] Manager login failed`);
      }
      const managerToken = JSON.parse(loginResponse.body).bearerToken;
      userTokenCache[`${tenant}:${users[managerIdx].userId}`] = managerToken;

      const projectSprints = [];
      for (let i = 0; i < 5; i++) {
        const sprintStart = new Date();
        sprintStart.setDate(sprintStart.getDate() + i * 14);
        const sprintEnd = new Date(sprintStart);
        sprintEnd.setDate(sprintEnd.getDate() + 13);

        const sprintResponse = http.post(
          `${BASE_URL}/api/sprint`,
          JSON.stringify({
            projectKey: project.projectKey,
            sprintName: `Sprint ${i + 1}`,
            startOfSprint: sprintStart.toISOString().split('T')[0],
            endOfSprint: sprintEnd.toISOString().split('T')[0],
          }),
          { headers: { 'Content-Type': 'application/json', Authorization: `${managerToken}`, tenant }, tags: { phase: 'setup' } }
        );
        if (sprintResponse && sprintResponse.status === 201) {
          projectSprints.push(JSON.parse(sprintResponse.body));
        }
      }

      tenantSprintMap[project.projectKey] = projectSprints;

      // Create 50 issues
      for (let i = 0; i < 50; i++) {
        const issue = {
          projectKey: project.projectKey,
          issueStatus: ['Backlog', 'In Progress', 'In Review', 'Tested', 'Done'][randomIntBetween(0, 4)],
          summary: `Issue ${randomString(12)} by ${users[managerIdx].email.split('@')[0]}`,
          details: `Created during batch test`,
          sprintId: null,
        };
        http.post(`${BASE_URL}/api/issue`, JSON.stringify(issue), {
          headers: { 'Content-Type': 'application/json', Authorization: `${managerToken}`, tenant },
          tags: { phase: 'setup' },
        });
      }

      // Grant access to slice of users
      const increment = Math.ceil(USERS_COUNT / PROJECTS_COUNT);
      const projectUsers = users.slice(0, increment);
      for (const user of projectUsers) {
        const accessResponse = http.post(
          `${BASE_URL}/api/access`,
          JSON.stringify({ userIds: [user.userId], projectKey: project.projectKey }),
          { headers: { 'Content-Type': 'application/json', Authorization: `${managerToken}`, tenant }, tags: { phase: 'setup' } }
        );
        if (accessResponse.status !== 201) {
          throw new Error(`[${tenant}] Failed to grant access to user: ${accessResponse.body}`);
        }
      }
    }
    sprintMap[tenant] = tenantSprintMap;
  }

  return { sprintMap };
}

export default function (data) {
  // Pick a random tenant and user per iteration
  const tenant = TENANTS[randomIntBetween(0, TENANTS.length - 1)];
  const users = tenantUsersMap[tenant];
  if (!users || users.length === 0) {
    return;
  }
  const tenantSprintMap = data.sprintMap[tenant] || {};

  const user = users[randomIntBetween(0, users.length - 1)];

  // Login if not cached
  const cacheKey = `${tenant}:${user.userId}`;
  if (!userTokenCache[cacheKey]) {
    const loginResponse = http.post(
      `${BASE_URL}/api/user/login`,
      JSON.stringify({ email: user.email, password: user.password }),
      { headers: { 'Content-Type': 'application/json', tenant }, tags: { phase: 'test', tenant, operation: 'login' } }
    );
    if (loginResponse.status !== 200) {
      return;
    }
    try {
      const userData = JSON.parse(loginResponse.body);
      userTokenCache[cacheKey] = userData.bearerToken;
    } catch (_) {
      return;
    }
  }

  const bearerToken = userTokenCache[cacheKey];

  // Get user's projects
  const userProjects = http.get(`${BASE_URL}/api/project/all`, {
    headers: { Authorization: `${bearerToken}`, tenant },
    tags: { phase: 'test', tenant, operation: 'getProjects' },
  });
  if (userProjects.status !== 200) {
    return;
  }
  const userProjectsList = JSON.parse(userProjects.body);
  if (!userProjectsList || userProjectsList.length === 0) {
    return;
  }
  const project = userProjectsList[randomIntBetween(0, userProjectsList.length - 1)];
  const opRoll = randomIntBetween(1, 100);

  if (opRoll <= 20) {
    createIssueOperation(tenant, user, bearerToken, project, tenantSprintMap);
  } else if (opRoll <= 80) {
    listIssuesOperation(tenant, user, bearerToken, project, tenantSprintMap);
  } else {
    updateIssueOperation(tenant, user, bearerToken, project);
  }
}

function createIssueOperation(tenant, user, bearerToken, project, tenantSprintMap) {
  const sprints = tenantSprintMap[project.projectKey] || [];
  const sprint = sprints.length > 0 ? sprints[randomIntBetween(0, sprints.length - 1)] : null;
  http.post(
    `${BASE_URL}/api/issue`,
    JSON.stringify({
      projectKey: project.projectKey,
      issueStatus: ['Backlog', 'In Progress', 'In Review', 'Deployed', 'Tested', 'Done'][randomIntBetween(0, 5)],
      summary: `Issue ${randomString(12)} by ${user.email.split('@')[0]}`,
      details: `Created during batch test`,
      sprintId: sprint ? sprint.sprintId : null,
    }),
    { headers: { 'Content-Type': 'application/json', Authorization: `${bearerToken}`, tenant }, tags: { phase: 'test', tenant, operation: 'createIssue' } }
  );
}

function listIssuesOperation(tenant, user, bearerToken, project, tenantSprintMap) {
  const offset = randomIntBetween(0, 30);
  let queryParams = `?limit=10&offset=${offset}`;
  const filterType = randomIntBetween(1, 3);
  if (filterType === 1 && tenantSprintMap[project.projectKey]) {
    const sprints = tenantSprintMap[project.projectKey];
    const sprint = sprints[randomIntBetween(0, sprints.length - 1)];
    queryParams += `&sprintIds[]=${sprint.sprintId}`;
  } else if (filterType === 2) {
    const statuses = ['Backlog', 'In%20Progress', 'In%20Review', 'Deployed', 'Tested', 'Done'];
    queryParams += `&issueStatuses[]=${statuses[randomIntBetween(0, statuses.length - 1)]}`;
  } else if (filterType === 3) {
    queryParams += `&assigneeIds[]=${user.userId}`;
  }
  http.get(`${BASE_URL}/api/issue/project/${project.projectKey}${queryParams}`, {
    headers: { Authorization: `${bearerToken}`, tenant },
    tags: { phase: 'test', tenant, operation: 'listIssues' },
  });
}

function updateIssueOperation(tenant, user, bearerToken, project) {
  const listResponse = http.get(`${BASE_URL}/api/issue/project/${project.projectKey}?limit=20&offset=0`, {
    headers: { Authorization: `${bearerToken}`, tenant },
    tags: { phase: 'test', tenant, operation: 'listIssues' },
  });
  if (listResponse.status === 200) {
    const issues = JSON.parse(listResponse.body);
    if (issues && issues.length > 0) {
      const issue = issues[randomIntBetween(0, issues.length - 1)];
      const statuses = ['Backlog', 'In Progress', 'In Review', 'Deployed', 'Tested', 'Done'];
      const updatePayload = {};
      const updateType = randomIntBetween(1, 3);
      if (updateType === 1 || updateType === 3) {
        updatePayload.issueStatus = statuses[randomIntBetween(0, statuses.length - 1)];
      }
      if (updateType === 2 || updateType === 3) {
        updatePayload.summary = `Updated ${randomString(8)} by ${user.email.split('@')[0]}`;
      }
      http.patch(`${BASE_URL}/api/issue/${issue.issueId}?projectKey=${project.projectKey}`, JSON.stringify(updatePayload), {
        headers: { 'Content-Type': 'application/json', Authorization: `${bearerToken}`, tenant },
        tags: { phase: 'test', tenant, operation: 'updateIssue' },
      });
    }
  }
}

export function teardown() {
  // nothing special
}


