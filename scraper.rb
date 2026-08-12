#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "mechanize"
require "json"
require "scraperwiki"

VERSION = "2.0"

# Require a delay between requests to avoid 429 => Net::HTTPTooManyRequests errors
# 10 to 20 worked, but added 5 seconds to be safer
DELAY_BETWEEN_REQUESTS_RANGE = 15.0...25.0

agent = Mechanize.new
agent.user_agent = "Ruby/#{RUBY_VERSION} PlanningAlerts scraper for SA Planning Portal/#{VERSION} (https://www.planningalerts.org.au/about)"
puts "Using user agent: #{agent.user_agent}"

agent.request_headers = {
  "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language" => "en-AU,en-GB;q=0.8,en-US;q=0.5,en;q=0.3",
  "Accept-Encoding" => "gzip, deflate",
  "Connection" => "keep-alive",
}
agent.follow_meta_refresh = true
agent.redirect_ok = true

proxy = ENV["MORPH_AUSTRALIAN_PROXY"]
if proxy
  # On morph.io set the environment variable MORPH_AUSTRALIAN_PROXY to
  # http://morph:password@au.proxy.oaf.org.au:8888 replacing password with
  # the real password.
  puts "Using Australian proxy..."
  agent.agent.set_proxy(proxy)
end

url = "https://plan.sa.gov.au/have_your_say/notified_developments/current_notified_developments"
puts "Visiting html page to set cookies: #{url} ..."
agent.get(url)

delay = rand(DELAY_BETWEEN_REQUESTS_RANGE)
total_delay = delay
puts "Delaying for #{delay.round(2)}s to avoid 429 Too Many Requests errors"
sleep(delay)

# This endpoint is not "protected" by Kasada, but probably is by Cloudflare
# url = "https://plan.sa.gov.au/have_your_say/notified_developments/current_notified_developments/assets/getpublicnoticessummary"
url = "https://cdn.plan.sa.gov.au/public-notifications/getpublicnoticessummary"
response = agent.post(url)
puts "Got #{response.code} response from #{url}"
applications = JSON.parse(response.body)
puts "Found #{applications.length} applications to process in random order with #{DELAY_BETWEEN_REQUESTS_RANGE} seconds between requests."

found_again = new_records = 0
count_per_authority = Hash.new(0)
count_per_property = Hash.new(0)
show_application = show_detail = true
# Randomise order to avoid looking so bot like AND get something done even if we are blocked after a few records
applications.shuffle.each do |application|
  council_reference = application["applicationID"]
  aid = application["publicNotificationID"]
  on_notice_to = Date.strptime(application["closingDate"], "%m/%d/%Y")
  description = application["developmentDescription"].gsub("&hellip;", "...")
  record = {
    "council_reference" => council_reference.to_s,
    # If there are multiple addresses they are all included in this field separated by ","
    # Only use the first address
    "address" => application["propertyAddress"].split(",").first,
    "description" => description,
    # Not clear whether this page will stay around after the notification period is over
    "info_url" => "https://plan.sa.gov.au/have_your_say/notified_developments/current_notified_developments/submission?aid=#{aid}",
    "date_scraped" => Date.today.to_s,
    "on_notice_to" => on_notice_to.to_s
  }

  existing = begin
               ScraperWiki.select("* from data where council_reference = ?", record["council_reference"])
             rescue StandardError => e
               puts "INFO: Ignoring #{e.message} while looking for existing record: #{record['council_reference']}"
               []
             end
  if existing&.length == 1
    record["comment_email"] = existing.first["comment_email"]
    record["comment_authority"] = existing.first["comment_authority"]
    record["on_notice_from"] = existing.first["on_notice_from"]
  end

  if record["comment_authority"].to_s != '' && record["comment_email"].to_s != ''
    puts "Reusing comment email and authority from existing record: #{record['council_reference']}"
    found_again += 1
  else
    # Click to https://plan.sa.gov.au/have_your_say/notified_developments/current_notified_developments/submission?aid=11823
    # Shows Term Of Use with Accept / Reject buttons
    delay = rand(DELAY_BETWEEN_REQUESTS_RANGE)
    puts "Retrieving comment email and authority from detail page for #{record['council_reference']} (aid=#{aid.inspect}, delay=#{delay.round(2)}s)"
    new_records += 1
    total_delay += delay
    sleep(delay)
    # Send comments to the individual councils from the details endpoint rather than PlanSA
    page = agent.post("https://cdn.plan.sa.gov.au/public-notifications/getpublicnoticedetail", aid: aid)
    if show_detail
      puts "Application data: #{application.inspect}"
      puts "Detail data: #{page.body}"
      show_application = show_detail = false
    end
    detail = JSON.parse(page.body)
    record["comment_email"] = detail["email"]
    record["comment_authority"] = detail["organisation"]
    on_notice_from = Date.strptime(detail["openingDate"], "%m/%d/%Y")
    record["on_notice_from"] = on_notice_from.to_s
    unless record["comment_authority"].to_s != '' && record["comment_email"].to_s != ''
      puts "WARNING: Could not find comment email and authority for #{record['council_reference']} from #{page.body}"
    end
  end

  count_per_authority[record["comment_authority"]] += 1
  puts "Saving record #{record['council_reference']}, #{record['address']}"
  ScraperWiki.save_sqlite(['council_reference'], record)
  record.each do |k, v|
    count_per_property[k] += 1 if v.to_s != ''
  end
end
if show_application
  puts "First Application data retrieved: #{applications.first.inspect}"
end
puts "",
     "Found #{found_again} applications that were already in the database, and added #{new_records} new applications.",
     "Added #{total_delay.round(2)} seconds total delay over #{new_records + 1} requests so server doesn't complain!",
     "",
     "Count  Authority",
     "-----  ------------------"

count_per_authority.sort.each do |authority, count|
  puts "#{count.to_s.rjust(5)}  #{authority}"
end

if ENV['DEBUG'] || ENV['MORPH_DEBUG']
  puts "",
       "Count  Non blank Attribute",
       "-----  -------------------"

  count_per_property.sort.each do |attribute, count|
    puts "#{count.to_s.rjust(5)}  #{attribute}"
  end
end
