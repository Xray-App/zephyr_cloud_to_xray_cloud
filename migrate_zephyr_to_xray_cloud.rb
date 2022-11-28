#!/usr/bin/env ruby

require 'rubygems'
require 'jira-ruby'
require 'json'
require 'rest-client'
require 'jwt'
require 'optparse'
require 'yaml'
require 'pry'

# https://github.com/sumoheavy/jira-ruby/blob/master/example.rb
# https://developer.atlassian.com/cloud/jira/platform/jira-rest-api-basic-authentication/
# https://zfjcloud.docs.apiary.io/#reference/teststep/create-and-get-all-teststep/get-all-teststeps
# https://confluence.atlassian.com/jirakb/how-to-use-rest-api-to-add-issue-links-in-jira-issues-939932271.html

=begin

Features:
- creates new Test issues, on the same or another project 
- source Test cases can be identified using JQL
- copies: summary, description, fixVersion, components, labels, priority, custom fields (single value and multivalue)  
- creates up to 1 link

Limitations:
- does not copy Test's  attachments, comments and other fields that are not described earlier
- doesnt recreate more than one link per Test issue
- does not process Test Cycles nor execution related information
- some fields are copied based on id an not on name
=end

OPTIONS = {}
config = YAML::load_file(File.join(__dir__, 'config.yml'))

XRAY_API_BASE_URL = config['xray_api_base_url']
ZAPI_BASE_URL = config['zapi_base_url']

JIRA_USER = config['jira_user']
JIRA_USERNAME = config['jira_username']
JIRA_ACCOUNTID = config['jira_accountid']
JIRA_PASSWORD = config['jira_api_token']
JIRA_SITE = config['jira_site']


XRAY_CLIENT_ID = config['xray_client_id']
XRAY_CLIENT_SECRET = config['xray_client_secret']


ZAPI_ACCESS_KEY = config['zapi_access_key']
ZAPI_SECRET_KEY = config['zapi_secret_key']
LABELS_TO_ADD = config['labels_to_add']
SIMPLE_FIELDS_TO_COPY = config['simple_fields_to_copy']
MULTIVALUES_FIELDS_TO_COPY = config['multivalues_fields_to_copy']

JQL = config['jql']
MAX_TESTS = config['max_tests'] || 1000
CREATE_ISSUE_LINKS = config['create_issue_links'] || false
PREFERRED_ISSUE_LINK_TYPE_TO_MIGRATE = config['preferred_issue_link_type_to_migrate'] || "Test"
DESTINATION_PROJECT_KEY = config['destination_project_key']
XRAY_TEST_TYPE = config['xray_test_type'] || "Manual"
MIGRATE_TESTS_WITH_EMPTY_STEPS = config['migrate_tests_with_empty_steps'] || false
JIRA_CLOUD_MAX_ISSUES_RETURNED_BY_REST_API = 100
XRAY_CLOUD_MAX_ISSUES_CREATED_IN_BULK = 1000

def bin_to_hex(s)
 s.unpack('H*')[0]
end

def jwt_token(url,testId,projectId)
  iat = Time.now.to_i
  exp = Time.now.to_i + 3600 * 1000
  hmac_secret = ZAPI_SECRET_KEY
  #puts url
  canonical_path="GET&/public/rest/api/1.0/teststep/#{testId}&projectId=#{projectId}"
  payload = { sub: JIRA_ACCOUNTID, iss: ZAPI_ACCESS_KEY, exp: exp, iat: iat , qsh: bin_to_hex(Digest::SHA256.digest(canonical_path))}
  token = JWT.encode payload, hmac_secret, 'HS256', { typ: 'JWT' }
  token
end

def get_test_steps(issueId, projectId)
  url = "#{ZAPI_BASE_URL}/connect/public/rest/api/1.0/teststep/#{issueId}?projectId=#{projectId}"
  headers = {
    :content_type => 'application/json',
    :authorization => "JWT " + jwt_token(url, issueId, projectId),
    :zapiaccesskey => ZAPI_ACCESS_KEY
  }  
  response = RestClient.get url, headers
  puts "RESPONSE: #{response.body}" if OPTIONS[:verbose]
  JSON.parse(response.body)
end


def authenticate_xray_api
  body = { "client_id": XRAY_CLIENT_ID,"client_secret": XRAY_CLIENT_SECRET }
  res = RestClient.post "#{XRAY_API_BASE_URL}/api/v1/authenticate", body.to_json, {content_type: :json, accept: :json}
  token = res.body[1..-2]
end
def create_xray_manual_test_object(original_test, zephyr_steps)
  steps = []
  zephyr_steps.each  do |step|
     step_content = { "action" => (step["step"].to_s.empty? ? "<empty>" : step["step"]), "data" => (step["data"] || ""), "result" => (step["result"] || "") }
     steps << step_content 
  end
  dest_proj_key = DESTINATION_PROJECT_KEY || original_test.project.key
  test = {
      "testtype" => XRAY_TEST_TYPE,
      "steps" => steps,
      "fields" => {
        "summary" => original_test.summary,
        "description" => original_test.description,
        "project"=> { "key"=> dest_proj_key},
        "labels" => original_test.labels | LABELS_TO_ADD,
#        "status" => { "id" => original_test.status.id },
        "priority" => !original_test.priority.nil? && { "id" => original_test.priority.id },
        "components" => original_test.components.collect{ |comp| {"name"=>comp.name} },
        "fixVersions" => original_test.fixVersions.collect{ |comp| {"name"=>comp.name} }
      }
    }
    SIMPLE_FIELDS_TO_COPY.each do |field|
      test["fields"][field] = eval("original_test.#{field}")
    end
    MULTIVALUES_FIELDS_TO_COPY.each do |field|
      test["fields"][field] = eval("original_test.#{field}")
    end

    if CREATE_ISSUE_LINKS && original_test.issuelinks.size>0
      # only process first one, due to Jira Cloud REST API limitation
      link = nil
      if PREFERRED_ISSUE_LINK_TYPE_TO_MIGRATE.nil?
        link = original_test.issuelinks.first
      else
        link = original_test.issuelinks.select { |issuelink| issuelink.type.name == PREFERRED_ISSUE_LINK_TYPE_TO_MIGRATE }.first
      end

      if !link.nil?
        test["update"] = {
          "issuelinks" => [                      
              {
                  "add" => {
                      "type" =>{
                          "name" => link.type.name
                      }
                  }
              }
          ]
        }
        test["update"]["issuelinks"][0]["add"]["inwardIssue"] = { "key"=> link.inwardIssue.key } if !link.inwardIssue.nil?
        test["update"]["issuelinks"][0]["add"]["outwardIssue"] = { "key"=> link.outwardIssue.key } if !link.outwardIssue.nil?
      end
    end

    puts test if OPTIONS[:verbose]
    test
end



def create_xray_tests_in_bulk(tests_metadata)
  puts "REQUEST_BULK: #{tests_metadata}" if OPTIONS[:verbose]
  puts "========================"
  res = RestClient.post "#{XRAY_API_BASE_URL}/api/v1/import/test/bulk", tests_metadata.to_json, {content_type: :json, accept: :json, authorization: "Bearer #{TOKEN}" }
  puts "RESPONSE: #{res}" if OPTIONS[:verbose]
  JSON.parse(res)
end

def get_import_status(jobId)
  res = RestClient.get "#{XRAY_API_BASE_URL}/api/v1/import/test/bulk/#{jobId}/status",  {content_type: :json, accept: :json, authorization: "Bearer #{TOKEN}" }
  puts "RESPONSE: #{res}" if OPTIONS[:verbose]
  JSON.parse(res)
end




#=============================
#          Main              #
#=============================

OptionParser.new do |opts|
  opts.banner = "Usage: migrate_zehyr_to_xray_cloud.rb [options]"
  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    OPTIONS[:verbose] = v
  end
end.parse!

TOKEN = authenticate_xray_api


jira_api_options = {
  :username     => JIRA_USER,
  :password     => JIRA_PASSWORD,
  :site         => JIRA_SITE,
  :context_path => '',
  :auth_type    => :basic,
}

client = JIRA::Client.new(jira_api_options)
total_issues_processed = 0
batch_number = 0

tests = []
loop do
  tests = []
  total_issues_obtained = 0
  batch_number += 1

  begin
    loop do
      max_allowed_results = [XRAY_CLOUD_MAX_ISSUES_CREATED_IN_BULK, MAX_TESTS, (XRAY_CLOUD_MAX_ISSUES_CREATED_IN_BULK-total_issues_obtained)].min
      break if max_allowed_results == 0

      source_issues = client.Issue.jql(JQL, max_results: max_allowed_results, start_at: total_issues_processed)
      puts "Issues batch amount to migrate: #{source_issues.size}"
      puts "Obtaining tests information..."
      source_issues.each do |issue| 
        zephyr_steps = get_test_steps(issue.id,issue.project.id)
        if !zephyr_steps.nil? && ((MIGRATE_TESTS_WITH_EMPTY_STEPS && zephyr_steps.size>0) || (!MIGRATE_TESTS_WITH_EMPTY_STEPS))
          test_metadata = create_xray_manual_test_object(issue, zephyr_steps)
          tests << test_metadata if !test_metadata.nil?
        end
      end
      total_issues_obtained += source_issues.size
      total_issues_processed += source_issues.size
      break if (source_issues.size == 0) || (source_issues.size < max_allowed_results)
    end

  rescue JIRA::HTTPError => e
    puts "HTTP error accessing JIRA:"
    puts "  code: #{e.response.code}"
    puts "  message: #{e.response.message}"
    puts "  body: '#{e.response.body}'"
  end

  if !tests.empty?
    puts "Creating tests in bulk (batch #{batch_number})..."
    res = create_xray_tests_in_bulk(tests)
    jobId = res["jobId"]
    status = "pending"
    if !jobId.nil?
      res = {}
      while ["pending","working"].include?(status) do    
        res = get_import_status(jobId)
        status = res["status"]
        puts status
        sleep 5
      end
      puts res["result"] if OPTIONS[:verbose]

      total_issues_not_migrated = res["result"]["errors"].size
      total_issues_migrated = res["result"]["issues"].size
      
      puts "Total tests not migrated: #{total_issues_not_migrated}" if total_issues_not_migrated > 0
      puts "Total tests migrated: #{total_issues_migrated}"
      puts "Issue keys of created tests: " + res["result"]["issues"].collect { |issue| issue["key"]}.join(',') if total_issues_migrated > 0
      if total_issues_not_migrated > 0
        puts "Errors from issues not created:"
        puts res["result"]["errors"]
      end
    end
  end

  break if tests.empty?
end

if tests.empty? && (total_issues_processed == 0)
  puts "Aborting. No tests to migrate..."
  exit 1
end

exit
