
# Features
 - creates (only) new Test issues, on the same or another project 
 - source Test cases can be identified using JQL
 - copies: summary, description, fixVersion, components, labels, priority, custom fields (single value and multivalue)  
 - recreates up to 1 link :(
 - ability to add labels to easily identify the created Test issues

# Limitations
 - does not copy Test's  attachments, comments and other fields that are not described earlier
 - doesnt recreate more than one link per Test issue
 - does not migrate inline existing test cases; it always creates new Tests issues
 - does not process Test Cycles nor execution related information
 - some fields are copied based on id an not on name


# Requirements
 - Ruby >= 2.3.3
 - rvm (http://www.rvm.io), to easily setup Ruby environment
 - bundler
 - having Zephyr for Jira Cloud, ZAPI for Jira Cloud and ZAPI for Jira Cloud installed in Jira Cloud instance


# Setup
 - rvm use 2.3.3
 - gem install bundler
 - bundle


# How to use

1. Create an API token in Jira, in order to obtain the jira_api_token, this can be done by accessing the following url: https://id.atlassian.com/manage/api-tokens
2. Create an API key in ZAPI, in order to obtain a Access Key and a Secret Key
3. Create an API key in Xray, in order to obtain a Client Id and a Client Secret
4. Edit the settings in config.yml  
5. Run it
```sh
$ migrate_zephyr_to_xray_cloud.rb 
```

The utility may also support some parameters.
In order to see the full syntax, please use: 
```sh
$ migrate_zephyr_to_xray_cloud.rb --help
```

