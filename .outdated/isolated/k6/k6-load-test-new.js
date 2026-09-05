import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { sleep } from 'k6';
import { SharedArray } from 'k6/data';
import http from 'k6/http';

// Configuration
const SCRIPT_DIR = __ENV.SCRIPT_DIR;
const TENANT = __ENV.TENANT;
const BASE_URL = `http://localhost:3000`;
const ADMIN_EMAIL = `admin@${TENANT}.dne.com`;
const ADMIN_PASSWORD = 'admin123!';
const PROJECTS_COUNT = __ENV.PROJECTS_COUNT || 10;
const USERS_COUNT = __ENV.USERS_COUNT || 50;

// Load test parameters - simulate a normal workday
// Total duration: 10 minutes
// 2 min ramp-up, 6 min steady-state, 2 min ramp-down
const RAMPUP_VUS = USERS_COUNT;      // Number of concurrent users during steady-state
const RAMPUP_DURATION = '10s';
const STEADY_DURATION = '10s';
const RAMPDOWN_DURATION = '10s';

if (!TENANT) {
  throw new Error('TENANT environment variable is required');
}

// Load all available users from CSV
const allUsers = new SharedArray('users', function () {
  const csvData = open(`${SCRIPT_DIR}/passwords/${TENANT}-users.csv`);
  const lines = csvData.split('\n');
  const userList = [];
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line) {
      const [userId, email, password] = line.split(',');
      userList.push({ userId, email, password });
    }
  }

  console.log(`Loaded ${userList.length} users from CSV`);
  return userList;
});

// Load test configuration with ramping stages
export const options = {
  stages: [
    { duration: RAMPUP_DURATION, target: RAMPUP_VUS },      // Ramp up to x VUs
    { duration: STEADY_DURATION, target: RAMPUP_VUS },      // Stay at x VUs
    { duration: RAMPDOWN_DURATION, target: 0 },             // Ramp down to 0 VUs
  ],
  thresholds: {
    // Load test phase: performance thresholds for normal workday
    'http_req_duration{phase:test}': [
      { threshold: 'p(95)<100', abortOnFail: false },    // 95% of requests under 100ms
      { threshold: 'p(99)<300', abortOnFail: false },    // 99% of requests under 300ms
    ],
    http_req_failed: ['rate<0.01'],                      // Less than 1% failure rate
  },
  setupTimeout: '3m',
};

// Global state
let adminToken = '';
let projects = [];
let userAccess = {}; // projectKey -> [userIds with access]
let sprintMap = {};
const userTokenCache = {}; // userId -> bearerToken (cached per VU)

// Called only once before the test starts
export function setup() {

  console.log(`LOAD TEST SETUP: \n\tTENANT: ${TENANT}\n\tBASE_URL: ${BASE_URL}\n\tADMIN_EMAIL: ${ADMIN_EMAIL}\n\tADMIN_PASSWORD: ${ADMIN_PASSWORD}\n\tPROJECTS_COUNT: ${PROJECTS_COUNT}\n\tUSERS_COUNT: ${USERS_COUNT}\n\tRAMPUP_VUS: ${RAMPUP_VUS}\n\tRampup: ${RAMPUP_DURATION}, Steady: ${STEADY_DURATION}, Rampdown: ${RAMPDOWN_DURATION}`);
  
  // STEP -3: Login as admin
  const adminLoginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
    email: ADMIN_EMAIL,
    password: ADMIN_PASSWORD
  }), {
    headers: { 'Content-Type': 'application/json' },
    tags: { phase: 'setup' }
  });
  
  if (adminLoginResponse.status !== 200) {
    throw new Error(`Admin login failed: ${adminLoginResponse.body}`);
  }
  
  const adminData = JSON.parse(adminLoginResponse.body);
  adminToken = adminData.adminBearerToken;
  console.log('Admin token obtained');
  
  // STEP -2: Create projects
  for (let i = 0; i < PROJECTS_COUNT; i++) {
    const managerIdx = Math.floor((i) / 2);
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
        'Authorization': `${adminToken}`
      },
      tags: { phase: 'setup' }
    });

    if (projectResponse && projectResponse.status === 201) {
      try {
        const project = JSON.parse(projectResponse.body);

        projects.push(project);
      } catch (parseError) {
        throw new Error(`Error parsing project creation response: ${parseError}`);
      }
    } else {
      throw new Error(`Project creation failed (status: ${projectResponse ? projectResponse.status : 'unknown'})`);
    }
  }
  
  console.log(`Created ${projects.length} projects`);
  
  // STEP -1: Create sprints for each project
  for (const project of projects) {
    const managerIdx = allUsers.findIndex(u => u.userId === project.managerId);
    if (managerIdx === -1) {
      throw new Error(`Manager not found for project ${project.projectKey}`);
    }
    
    const manager = allUsers[managerIdx];
    // login as manager
    const loginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
      email: manager.email,
      password: manager.password
    }), {
      headers: { 'Content-Type': 'application/json' },
      tags: { phase: 'setup' }
    });
    if (loginResponse.status !== 200) {
      throw new Error(`Manager login failed: ${loginResponse.body}`);
    }
    const managerData = JSON.parse(loginResponse.body);
    const managerToken = managerData.bearerToken;

    userTokenCache[manager.userId] = managerToken;
    
    const projectSprints = [];
    
    // Create 3 sprints for the project
    for (let i = 0; i < 3; i++) {
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
          'Authorization': `${managerToken}`
        },
        tags: { phase: 'setup' }
      });

      if (sprintResponse && sprintResponse.status === 201) {
        try {
          const sprint = JSON.parse(sprintResponse.body);
          projectSprints.push(sprint);
          sprintMap[project.projectKey] = projectSprints;
        } catch (e) {
          throw new Error(`Error parsing sprint creation response: ${e}`);
        }
      } else {
        throw new Error(`Failed to create sprint for project ${project.projectKey}: ${sprintResponse.body}`);
      }
    }

    // Create 30 issues for the project (less than stress test)
    for (let i = 0; i < 50; i++) {
      const issue = {
        projectKey: project.projectKey,
        issueStatus: ['Backlog', 'In Progress', 'In Review', 'Tested', 'Done'][randomIntBetween(0, 4)],
        summary: `Issue ${randomString(12)} by ${manager.email.split('@')[0]}`,
        details: `Created during load test at ${new Date().toISOString()}`,
        sprintId: null
      };

      const createIssueResponse = http.post(`${BASE_URL}/api/issue`, JSON.stringify(issue), {
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `${managerToken}`
        },
        tags: { phase: 'setup' }
      });
      if (createIssueResponse.status !== 201) {
        throw new Error(`Failed to create issue: ${createIssueResponse.body}`);
      }
    }

    console.log(`Created 30 issues for project ${project.projectKey}`);

    // Generate user access on project
    // Grant access to first USERS_COUNT users
    const projectUsers = allUsers.slice(0, USERS_COUNT);

    for (const user of projectUsers) {
      const accessResponse = http.post(`${BASE_URL}/api/access`, JSON.stringify({
        userIds: [user.userId],
        projectKey: project.projectKey
      }), {
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `${managerToken}`
        },
        tags: { phase: 'setup' }
      });

      if (accessResponse.status !== 201) {
        throw new Error(`Failed to grant access to user: ${accessResponse.body}`);
      }
    }

    console.log(`Granted access for project ${project.projectKey} to ${projectUsers.length} users`);
  }
  
  return { userAccess, sprintMap };
}

export default function(data) {
  const { userAccess, sprintMap } = data;

  // Select user based on VU ID for distribution
  const user = allUsers[__VU-1];
  console.log(`userID: ${user.userId}`);

  // Log in user if not already cached
  if (!userTokenCache[user.userId]) {
    const loginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
      email: user.email,
      password: user.password
    }), {
      headers: { 'Content-Type': 'application/json' },
      tags: { phase: 'test' }
    });
    
    if (loginResponse.status !== 200) {
      console.error(`User login failed for ${user.email}: ${loginResponse.body}`);
      return;
    }
    
    try {
      const userData = JSON.parse(loginResponse.body);
      userTokenCache[user.userId] = userData.bearerToken;
    } catch (e) {
      console.error(`Failed to parse login response: ${e}`);
      return;
    }
  }
  
  const bearerToken = userTokenCache[user.userId];
  
  // Find user's projects
  const userProjects = http.get(`${BASE_URL}/api/project/all`, {
    headers: {
      'Authorization': `${bearerToken}`
    },
    tags: { phase: 'test' }
  });
  
  if (userProjects.status !== 200) {
    console.error(`Failed to get user projects: ${userProjects.body}`);
    return;
  }

  const projects = JSON.parse(userProjects.body);

  if (!projects || projects.length === 0) {
    console.error('User has no projects' + user.email);
    return;
  }

  // Simulate normal workday - fewer operations than stress test
  const actions = randomIntBetween(50, 100);
  
  // Operation mix: 20% create, 60% list/filter, 20% update
  for (let i = 0; i < actions; i++) {
    const project = projects[randomIntBetween(0, projects.length - 1)];
    const operation = randomIntBetween(1, 100);
    
    if (operation <= 20) {
      createIssueOperation(user, bearerToken, project, sprintMap);
    } else if (operation <= 80) {
      listIssuesOperation(user, bearerToken, project, sprintMap);
    } else {
      updateIssueOperation(user, bearerToken, project);
    }

    sleep(randomIntBetween(3, 5));
  }

  // logout
  sleep(3)
  const logoutResponse = http.post(`${BASE_URL}/api/user/logout`, {}, {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `${bearerToken}`
    },
    tags: { phase: 'test' }
  });
  if (logoutResponse.status !== 200) {
    console.error(`Failed to logout: ${JSON.stringify(logoutResponse)}`);
  }
}

function createIssueOperation(user, bearerToken, project, sprintMap) {
  const sprints = sprintMap[project.projectKey] || [];
  const sprint = sprints.length > 0 ? sprints[randomIntBetween(0, sprints.length - 1)] : null;

  const issueResponse = http.post(`${BASE_URL}/api/issue`, JSON.stringify({
    projectKey: project.projectKey,
    issueStatus: ['Backlog', 'In Progress', 'In Review', 'Deployed', 'Tested', 'Done', 'Rejected'][randomIntBetween(0, 6)],
    summary: `Issue ${randomString(12)} by ${user.email.split('@')[0]}`,
    details: `Created during load test at ${new Date().toISOString()}`,
    sprintId: sprint ? sprint.sprintId : null
  }), {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `${bearerToken}`
    },
    tags: { phase: 'test' }
  });

  if (issueResponse.status !== 201) {
    console.error(`Failed to create issue: ${JSON.stringify(issueResponse)}`);
    throw new Error(`Failed to create issue: ${issueResponse.body}`);
  }
}

function listIssuesOperation(user, bearerToken, project, sprintMap) {
  // Build query parameters
  const offset = randomIntBetween(0, 30);
  let queryParams = `?limit=10&offset=${offset}`;

  // Random filtering options
  const filterType = randomIntBetween(1, 3);
  if (filterType === 1 && sprintMap[project.projectKey]) {
    const sprints = sprintMap[project.projectKey];
    const sprint = sprints[randomIntBetween(0, sprints.length - 1)];
    queryParams += `&sprintIds[]=${sprint.sprintId}`;
  } else if (filterType === 2) {
    const statuses = ['Backlog', 'In%20Progress', 'In%20Review', 'Deployed', 'Tested', 'Done', 'Rejected'];
    queryParams += `&issueStatuses[]=${statuses[randomIntBetween(0, statuses.length - 1)]}`;
  } else if (filterType === 3) {
    queryParams += `&assigneeIds[]=${user.userId}`;
  }

  const listResponse = http.get(
    `${BASE_URL}/api/issue/project/${project.projectKey}${queryParams}`,
    {
      headers: {
        'Authorization': `${bearerToken}`
      },
      tags: { phase: 'test' }
    }
  );

  if (listResponse.status !== 200) {
    console.error(`Failed to list issues: ${JSON.stringify(listResponse)}`);
    throw new Error(`Failed to list issues: ${listResponse.status}`);
  }

  // Parse and potentially update one of the issues
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
  // First, get issues for the project
  const listResponse = http.get(
    `${BASE_URL}/api/issue/project/${project.projectKey}?limit=100&offset=0`,
    {
      headers: {
        'Authorization': `${bearerToken}`
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
  } else {
    console.error(`Failed to list issues: ${JSON.stringify(listResponse)}`);
    throw new Error(`Failed to list issues: ${listResponse.body}`);
  }
}

function updateSpecificIssue(user, bearerToken, issue, project) {
  const statuses = ['Backlog', 'In Progress', 'In Review', 'Deployed', 'Tested', 'Done', 'Rejected'];
  const updatePayload = {};

  // Random update: status, summary, or both
  const updateType = randomIntBetween(1, 3);
  if (updateType === 1 || updateType === 3) {
    updatePayload.issueStatus = statuses[randomIntBetween(0, statuses.length - 1)];
  }
  if (updateType === 2 || updateType === 3) {
    updatePayload.summary = `Updated ${randomString(8)} by ${user.email.split('@')[0]}`;
  }

  const updateResponse = http.patch(
    `${BASE_URL}/api/issue/${issue.issueId}?projectKey=${project.projectKey}`,
    JSON.stringify(updatePayload),
    {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `${bearerToken}`
      },
      tags: { phase: 'test' }
    }
  );

  if (updateResponse.status !== 200) {
    console.error(`Failed to update issue: ${JSON.stringify(updateResponse)}`);
    throw new Error(`Failed to update issue: ${updateResponse.body}`);
  }
}

export function teardown(data) {
  console.log('Load test completed');
}
