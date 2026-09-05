import { randomIntBetween, randomString } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';
import { check } from 'k6';
import { SharedArray } from 'k6/data';
import http from 'k6/http';

// Configuration
const SCRIPT_DIR = __ENV.SCRIPT_DIR;
const PROJECTS_COUNT = __ENV.PROJECTS_COUNT || 20;
const TENANT = __ENV.TENANT;
const BASE_URL = __ENV.BASE_URL || `http://localhost:3000`;
const ADMIN_EMAIL = `admin@${TENANT}.dne.com`;
const ADMIN_PASSWORD = 'admin123!';

if (!TENANT) {
  throw new Error('TENANT environment variable is required');
}

// Load users from CSV
const users = new SharedArray('users', function () {
  const csvData = open(`${SCRIPT_DIR}/passwords/${TENANT}/${TENANT}.csv`);
  const lines = csvData.split('\n');
  const userList = [];
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line) {
      const [userId, email, password] = line.split(',');
      userList.push({ userId, email, password, bearerToken: null });
    }
  }

  console.log(`Loaded ${userList.length} users for tenant ${TENANT}`);
  return userList;
});

// Test configuration
export const options = {
  vus: PROJECTS_COUNT,
  duration: '3m',
  iterations: PROJECTS_COUNT,
  thresholds: {
    http_req_duration: ['p(99)<1000'],
    http_req_failed: ['rate<0.01'],
  },
};

// Global state
let adminToken = '';
let projects = [];
let userMap = {};

// Called only once before the test starts
export function setup() {
  console.log(`Starting test for tenant: ${TENANT}`);
  
  // STEP -3: Login as admin
  const adminLoginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
    email: ADMIN_EMAIL,
    password: ADMIN_PASSWORD
  }), {
    headers: { 
      'Content-Type': 'application/json',
      'tenant': TENANT
    }
  });
  
  if (adminLoginResponse.status !== 200) {
    throw new Error(`Admin login failed: ${adminLoginResponse.body}`);
  }
  
  const adminData = JSON.parse(adminLoginResponse.body);
  adminToken = adminData.bearerToken;

  console.log('Admin logged in successfully');
  
  // STEP -2: Get users from CSV (already loaded in SharedArray)
  console.log(`Found ${users.length} users from CSV`);
  
  // STEP -1: Create 20 projects with 10 managers (2 projects each)
  const managers = users.slice(0, 10);
  
  for (let i = 0; i < PROJECTS_COUNT; i++) {
    console.log(`Creating project ${i + 1} of ${PROJECTS_COUNT}`);
    const manager = managers[i % managers.length];
    const projectName = `Project ${randomString(8)}`;
    const projectKey = `PRO${i+1}`;

    const projectResponse = http.post(`${BASE_URL}/api/project`, JSON.stringify({
      projectName: projectName,
      projectKey: projectKey,
      managerId: manager.userId
    }), {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `${adminToken}`,
        'tenant': TENANT
      }
    });

    if (projectResponse && projectResponse.status === 201) {
      try {
        const project = JSON.parse(projectResponse.body);
        if (project) {
          projects.push(project);
        } else {
          console.error(`Failed to parse project response body: ${projectResponse.body}`);
        }
      } catch (parseError) {
        console.error(`Error parsing project creation response: ${parseError}, body: ${projectResponse.body}`);
      }
    } else {
      console.error(`Project creation failed (status: ${projectResponse ? projectResponse.status : 'unknown'}): ${projectResponse ? projectResponse.body : 'No response body'}`);
    }
  }
  
  console.log(`Created ${projects.length} projects`);
  
  // STEP 0: Login all users and store in map
  for (const user of users) {
    const userLoginResponse = http.post(`${BASE_URL}/api/user/login`, JSON.stringify({
      email: user.email,
      password: user.password
    }), {
      headers: { 
        'Content-Type': 'application/json',
        'tenant': TENANT
      }
    });
    
    if (userLoginResponse.status === 200) {
      const userData = JSON.parse(userLoginResponse.body);
      userMap[user.userId] = {
        email: user.email,
        password: user.password,
        bearerToken: userData.bearerToken,
        userId: user.userId,
      };
    } else {
      console.error(`User login failed (status: ${userLoginResponse ? userLoginResponse.status : 'unknown'}): ${userLoginResponse ? userLoginResponse.body : 'No response body'}`);
    }
  }
  
  console.log(`Logged in ${Object.keys(userMap).length} users`);
  
  return { projects, userMap };
}

export default function(data) {
  const { projects, userMap } = data;

  console.log(`VU ${__VU} processing project`);
  const project = projects[__VU-1];
  
  if (!project) {
    console.error(`No project found for VU ${__VU}`);
    return;
  }
  
  const uniqueUserKeys = getNUniqueRandomArrayElements(10, Object.keys(userMap));
  const projectUsers = uniqueUserKeys.map(key => userMap[key]);

  // Create sprints for the project
  const projectManager = userMap[project.managerId];
  if (!projectManager || !projectManager.bearerToken) {
    console.error(`Project manager not found for project ${project.projectKey}`);
    return;
  }
  createSprintsForManager(projectManager, project);
  
  grantAccessToUsers(projectManager, project, projectUsers);

  // Create issues in parallel for project users
  for (const user of projectUsers) {
    createIssues(user, project);
  }
}

function createSprintsForManager(manager, project) {
  const startDate = new Date();
  
  // Create 10 sprints, 2 weeks apart
  for (let i = 0; i < 10; i++) {
    const sprintStart = new Date(startDate.getTime() + (i * 14 * 24 * 60 * 60 * 1000));
    const sprintEnd = new Date(sprintStart.getTime() + (13 * 24 * 60 * 60 * 1000));
    
    const sprintResponse = http.post(`${BASE_URL}/api/sprint`, JSON.stringify({
      projectKey: project.projectKey,
      sprintName: `Sprint ${i + 1}`,
      startOfSprint: sprintStart.toISOString().split('T')[0],
      endOfSprint: sprintEnd.toISOString().split('T')[0]
    }), {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `${manager.bearerToken}`,
        'tenant': TENANT
      }
    });
    
    check(sprintResponse, {
      'sprint created successfully': (r) => r.status === 201,
    });
  }
}

function grantAccessToUsers(manager, project, users) {
  const userIds = users.map(user => user.userId);
  const accessResponse = http.post(`${BASE_URL}/api/access`, JSON.stringify({
    userIds,
    projectKey: project.projectKey
  }), {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `${manager.bearerToken}`,
      'tenant': TENANT
    }
  });

  if (accessResponse.status !== 201) {
    console.error(`Access grant failed (status: ${accessResponse ? accessResponse.status : 'unknown'}): ${accessResponse ? accessResponse.body : 'No response body'}`);
  }
  
  check(accessResponse, {
    'access granted successfully': (r) => r.status === 201,
  });
}

function createIssues(user, project) {
  const issueCount = 15;
  
  for (let i = 0; i < issueCount; i++) {
    const issueResponse = http.post(`${BASE_URL}/api/issue`, JSON.stringify({
      projectKey: project.projectKey,
      issueStatus: ['Backlog', 'In Progress', 'In Review'][randomIntBetween(0, 2)],
      summary: `Issue ${user.email} ${project.projectKey} ${i + 1}`,
      details: `Issue created by ${user.email} for project ${project.projectKey}`
    }), {
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `${user.bearerToken}`,
        'tenant': TENANT
      }
    });

    if (issueResponse.status !== 201) {
      console.error(`Issue creation failed (status: ${issueResponse ? issueResponse.status : 'unknown'}): ${issueResponse ? issueResponse.body : 'No response body'}`);
    }
    
    check(issueResponse, {
      'issue created successfully': (r) => r.status === 201,
    });
  }
}

export function teardown() {
  console.log('Test completed');
}

function getNUniqueRandomArrayElements(n, array) {
  if (n >= array.length) {
    throw new Error(`N is greater than the length of the array`);
  }

  const indexes = Array.from(array.keys())

  for (let i = indexes.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [indexes[i], indexes[j]] = [indexes[j], indexes[i]];
  }

  return indexes.slice(0, n).map(index => array[index]);
}

