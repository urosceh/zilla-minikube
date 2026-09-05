import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { SharedArray } from 'k6/data';
import http from 'k6/http';

// Configuration
const SCRIPT_DIR = __ENV.SCRIPT_DIR;
const TENANT = __ENV.TENANT;
const BASE_URL = __ENV.BASE_URL || `http://localhost:3000`;
const ADMIN_EMAIL = `admin@${TENANT}.dne.com`;
const ADMIN_PASSWORD = 'admin123!';
const PROJECTS_COUNT = __ENV.PROJECTS_COUNT || 10;
const USERS_COUNT = __ENV.USERS_COUNT || 50;

// Load test parameters - simulate a normal workday
// Total duration: 10 minutes
// 2 min ramp-up, 6 min steady-state, 2 min ramp-down
const RAMPUP_VUS = 30;
const RAMPUP_DURATION = '30s';
const STEADY_DURATION = '120s';
const RAMPDOWN_DURATION = '30s';

if (!TENANT) {
  throw new Error('TENANT environment variable is required');
}

// Load all available users from CSV
const allUsers = new SharedArray('users', function () {
  console.log("CSV LOCATION: ", `${SCRIPT_DIR}/passwords/${TENANT}/${TENANT}.csv`);
  const csvData = open(`${SCRIPT_DIR}/passwords/${TENANT}/${TENANT}.csv`);
  const lines = csvData.split('\n');
  const userList = [];
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line) {
      const [userId, email, password] = line.split(',');
      userList.push({ userId, email, password });
    }
  }

  console.log(`[${TENANT}] Loaded ${userList.length} users from CSV`);
  return userList;
});

// Load test configuration with ramping stages
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
    http_req_failed: ['rate<0.01'],
  },
  setupTimeout: '3m',
  gracefulStop: '30s',
};

// Global state
let adminToken = '';
let projects = [];
let sprintMap = {};
const userTokenCache = {};

export function setup() {
  console.log(`[${TENANT}] LOAD TEST SETUP`);
  
  // Login as admin
  const adminLoginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
    email: ADMIN_EMAIL,
    password: ADMIN_PASSWORD
  }), {
    headers: { 
      'Content-Type': 'application/json',
      'tenant': TENANT
    },
    tags: { phase: 'setup' }
  });
  
  if (adminLoginResponse.status !== 200) {
    throw new Error(`[${TENANT}] Admin login failed: ${adminLoginResponse.body}`);
  }
  
  const adminData = JSON.parse(adminLoginResponse.body);
  adminToken = adminData.adminBearerToken;
  console.log(`[${TENANT}] Admin token obtained`);
  
  // Create projects
  for (let i = 0; i < PROJECTS_COUNT; i++) {
    const managerIdx = Math.floor((i) / 2) % allUsers.length;
    const manager = allUsers[managerIdx];
    const projectName = `LoadTest-Project-${i}-${randomString(4)}`;
    const projectKey = `LDT${i}`;

    const projectResponse = http.post(`${BASE_URL}/api/project`, JSON.stringify({
      projectName: projectName,
      projectKey: projectKey,
      managerId: manager.userId
    }), {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `${adminToken}`,
        'tenant': TENANT
      },
      tags: { phase: 'setup' }
    });

    if (projectResponse && projectResponse.status === 201) {
      try {
        const project = JSON.parse(projectResponse.body);
        projects.push(project);
      } catch (parseError) {
        throw new Error(`[${TENANT}] Error parsing project: ${parseError}`);
      }
    } else {
      throw new Error(`[${TENANT}] Project creation failed`);
    }
  }
  
  console.log(`[${TENANT}] Created ${projects.length} projects`);
  
  // Create sprints for each project
  for (let i = 0; i < projects.length; i++) {
    const project = projects[i];
    
    const managerIdx = allUsers.findIndex(u => u.userId === project.managerId);
    if (managerIdx === -1) {
      throw new Error(`[${TENANT}] Manager not found for project ${project.projectKey}`);
    }
    
    const manager = allUsers[managerIdx];
    const loginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
      email: manager.email,
      password: manager.password
    }), {
      headers: { 
        'Content-Type': 'application/json',
        'tenant': TENANT
      },
      tags: { phase: 'setup' }
    });
    
    if (loginResponse.status !== 200) {
      throw new Error(`[${TENANT}] Manager login failed`);
    }
    
    const managerData = JSON.parse(loginResponse.body);
    const managerToken = managerData.bearerToken;
    userTokenCache[manager.userId] = managerToken;
    
    const projectSprints = [];
    
    for (let i = 0; i < 5; i++) {
      const sprintStart = new Date();
      sprintStart.setDate(sprintStart.getDate() + i * 14);
      const sprintEnd = new Date(sprintStart);
      sprintEnd.setDate(sprintEnd.getDate() + 13);
      
      const sprintResponse = http.post(`${BASE_URL}/api/sprint`, JSON.stringify({
        projectKey: project.projectKey,
        sprintName: `Sprint ${i + 1}`,
        startOfSprint: sprintStart.toISOString().split('T')[0],
        endOfSprint: sprintEnd.toISOString().split('T')[0]
      }), {
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `${managerToken}`,
          'tenant': TENANT
        },
        tags: { phase: 'setup' }
      });

      if (sprintResponse && sprintResponse.status === 201) {
        try {
          const sprint = JSON.parse(sprintResponse.body);
          projectSprints.push(sprint);
        } catch (e) {
          throw new Error(`[${TENANT}] Error parsing sprint: ${e}`);
        }
      }
    }

    console.log(`Created 5 sprints for project ${project.projectKey}`);

    sprintMap[project.projectKey] = projectSprints;

    // Create issues
    for (let i = 0; i < 50; i++) {
      const issue = {
        projectKey: project.projectKey,
        issueStatus: ['Backlog', 'In Progress', 'In Review', 'Tested', 'Done'][randomIntBetween(0, 4)],
        summary: `Issue ${randomString(12)} by ${manager.email.split('@')[0]}`,
        details: `Created during load test`,
        sprintId: null
      };

      http.post(`${BASE_URL}/api/issue`, JSON.stringify(issue), {
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `${managerToken}`,
          'tenant': TENANT
        },
        tags: { phase: 'setup' }
      });
    }

    console.log(`Created 50 issues for project ${project.projectKey}`);

    // Grant access to users
    const increment = Math.ceil(USERS_COUNT / PROJECTS_COUNT);
    const projectUsers = allUsers.slice(i * increment, (i + 1) * increment);
    console.log(`Granting access for project ${project.projectKey} ${i}. ${increment} users`);
    for (const user of projectUsers) {
      const accessResponse = http.post(`${BASE_URL}/api/access`, JSON.stringify({
        userIds: [user.userId],
        projectKey: project.projectKey
      }), {
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `${managerToken}`,
          'tenant': TENANT
        },
        tags: { phase: 'setup' }
      });

      if (accessResponse.status !== 201) {
        throw new Error(`[${TENANT}] Failed to grant access to user: ${accessResponse.body}`);
      }      
    }

    console.log(`Granted access for project ${project.projectKey} to ${projectUsers.length} users`);
  }
  
  console.log(`[${TENANT}] Setup complete`);
  return { sprintMap };
}

export default function(data) {
  const { sprintMap } = data;

  const userIdx = __VU % allUsers.length;
  const user = allUsers[userIdx];

  // Login if not cached
  if (!userTokenCache[user.userId]) {
    const loginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
      email: user.email,
      password: user.password
    }), {
      headers: { 
        'Content-Type': 'application/json',
        'tenant': TENANT
      },
      tags: { phase: 'test' }
    });
    
    if (loginResponse.status !== 200) {
      return;
    }
    
    try {
      const userData = JSON.parse(loginResponse.body);
      userTokenCache[user.userId] = userData.bearerToken;
    } catch (e) {
      return;
    }
  }
  
  const bearerToken = userTokenCache[user.userId];
  
  // Get user's projects
  const userProjects = http.get(`${BASE_URL}/api/project/all`, {
    headers: {
      'Authorization': `${bearerToken}`,
      'tenant': TENANT
    },
    tags: { phase: 'test' }
  });
  
  if (userProjects.status !== 200) {
    return;
  }

  const userProjectsList = JSON.parse(userProjects.body);

  if (!userProjectsList || userProjectsList.length === 0) {
    return;
  }

  const project = userProjectsList[randomIntBetween(0, userProjectsList.length - 1)];
  const operation = randomIntBetween(1, 100);
  
  if (operation <= 20) {
    createIssueOperation(user, bearerToken, project, sprintMap);
  } else if (operation <= 80) {
    listIssuesOperation(user, bearerToken, project, sprintMap);
  } else {
    updateIssueOperation(user, bearerToken, project);
  }
}

function createIssueOperation(user, bearerToken, project, sprintMap) {
  const sprints = sprintMap[project.projectKey] || [];
  const sprint = sprints.length > 0 ? sprints[randomIntBetween(0, sprints.length - 1)] : null;

  http.post(`${BASE_URL}/api/issue`, JSON.stringify({
    projectKey: project.projectKey,
    issueStatus: ['Backlog', 'In Progress', 'In Review', 'Deployed', 'Tested', 'Done'][randomIntBetween(0, 5)],
    summary: `Issue ${randomString(12)} by ${user.email.split('@')[0]}`,
    details: `Created during load test`,
    sprintId: sprint ? sprint.sprintId : null
  }), {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `${bearerToken}`,
      'tenant': TENANT
    },
    tags: { phase: 'test' }
  });
}

function listIssuesOperation(user, bearerToken, project, sprintMap) {
  const offset = randomIntBetween(0, 30);
  let queryParams = `?limit=10&offset=${offset}`;

  const filterType = randomIntBetween(1, 3);
  if (filterType === 1 && sprintMap[project.projectKey]) {
    const sprints = sprintMap[project.projectKey];
    const sprint = sprints[randomIntBetween(0, sprints.length - 1)];
    queryParams += `&sprintIds[]=${sprint.sprintId}`;
  } else if (filterType === 2) {
    const statuses = ['Backlog', 'In%20Progress', 'In%20Review', 'Deployed', 'Tested', 'Done'];
    queryParams += `&issueStatuses[]=${statuses[randomIntBetween(0, statuses.length - 1)]}`;
  } else if (filterType === 3) {
    queryParams += `&assigneeIds[]=${user.userId}`;
  }

  const listResponse = http.get(
    `${BASE_URL}/api/issue/project/${project.projectKey}${queryParams}`,
    {
      headers: {
        'Authorization': `${bearerToken}`,
        'tenant': TENANT
      },
      tags: { phase: 'test' }
    }
  );

  if (listResponse.status === 200) {
    const issues = JSON.parse(listResponse.body);
    if (issues && issues.length > 0) {
      const issue = issues[randomIntBetween(0, Math.min(issues.length - 1, 9))];
      if (issue && issue.issueId && randomIntBetween(0, 100) > 70) {
        updateSpecificIssue(user, bearerToken, issue, project);
      }
    }
  }
}

function updateIssueOperation(user, bearerToken, project) {
  const listResponse = http.get(
    `${BASE_URL}/api/issue/project/${project.projectKey}?limit=20&offset=0`,
    {
      headers: {
        'Authorization': `${bearerToken}`,
        'tenant': TENANT
      },
      tags: { phase: 'test' }
    }
  );

  if (listResponse.status === 200) {
    const issues = JSON.parse(listResponse.body);
    if (issues && issues.length > 0) {
      const issue = issues[randomIntBetween(0, issues.length - 1)];
      updateSpecificIssue(user, bearerToken, issue, project);
    }
  }
}

function updateSpecificIssue(user, bearerToken, issue, project) {
  const statuses = ['Backlog', 'In Progress', 'In Review', 'Deployed', 'Tested', 'Done'];
  const updatePayload = {};

  const updateType = randomIntBetween(1, 3);
  if (updateType === 1 || updateType === 3) {
    updatePayload.issueStatus = statuses[randomIntBetween(0, statuses.length - 1)];
  }
  if (updateType === 2 || updateType === 3) {
    updatePayload.summary = `Updated ${randomString(8)} by ${user.email.split('@')[0]}`;
  }

  http.patch(
    `${BASE_URL}/api/issue/${issue.issueId}?projectKey=${project.projectKey}`,
    JSON.stringify(updatePayload),
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `${bearerToken}`,
        'tenant': TENANT
      },
      tags: { phase: 'test' }
    }
  );
}

export function teardown(data) {
  console.log(`[${TENANT}] Load test completed`);
}
