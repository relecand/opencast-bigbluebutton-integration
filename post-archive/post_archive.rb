require 'trollop'         #Commandline Parser
require 'rest-client'     #Easier HTTP Requests
require 'nokogiri'        #XML-Parser
require 'fileutils'       #Directory Creation
require 'mini_magick'     #Image Conversion
require 'streamio-ffmpeg' #Accessing video information
require File.expand_path('../../../lib/recordandplayback', __FILE__)  # BBB Utilities

require_relative 'oc_modules/oc_dublincore'
require_relative 'oc_modules/oc_acl'
require_relative 'oc_modules/oc_util'

### opencast configuration begin

# Server URL
# oc_server = 'https://develop.opencast.org'
$oc_server = '{{opencast_server}}'

# User credentials allowed to ingest via HTTP basic
# oc_user = 'username'
# oc_password = 'password'
$oc_user = '{{opencast_user}}'
$oc_password = '{{opencast_password}}'

# Workflow to use for ingest
# oc_workflow = 'bbb-upload'
$oc_workflow = 'bbb-upload'

# Adds the shared notes etherpad from a meeting to the attachments in Opencast
# Suggested default: false
$sendSharedNotesEtherpadAsAttachment = false

# Adds the public chat from a meeting to the attachments in Opencast as a subtitle file
# Suggested default: false
$sendChatAsSubtitleAttachment = false

# Default roles for the event, e.g. "ROLE_OAUTH_USER, ROLE_USER_BOB"
# Suggested default: ""
$defaultRolesWithReadPerm = '{{opencast_rolesWithReadPerm}}'
$defaultRolesWithWritePerm = '{{opencast_rolesWithWritePerm}}'

# Whether a new series should be created if the given one does not exist yet
# Suggested default: false
$createNewSeriesIfItDoesNotYetExist = '{{opencast_createNewSeriesIfItDoesNotYetExist}}'

# Default roles for the series, e.g. "ROLE_OAUTH_USER, ROLE_USER_BOB"
# Suggested default: ""
$defaultSeriesRolesWithReadPerm = '{{opencast_seriesRolesWithReadPerm}}'
$defaultSeriesRolesWithWritePerm = '{{opencast_seriesRolesWithWritePerm}}'

# The given dublincore identifier will also passed to the dublincore source tag,
# even if the given identifier cannot be used as the actual identifier for the vent
# Suggested default: false
$passIdentifierAsDcSource = false

# Flow control booleans
# Suggested default: false
$onlyIngestIfRecordButtonWasPressed = '{{opencast_onlyIngestIfRecordButtonWasPressed}}'

# If a converted video already exists, don't overwrite it
# This can save time when having to run this script on the same input multiple times
# Suggested default: false
$doNotConvertVideosAgain = true

# Monitor Opencast workflow state after ingest to determine whether the workflow was successful.
# WARNING! Will stop processing of further recordings until the Opencast workflow completes. Do not use in production!
# EXPERIMENTIAL! This may cause the process spawned from this script to run a lot longer than anticipated.
# Suggested default: false
$monitorOpencastAfterIngest = false
# Time between each state check in seconds
$secondsBetweenChecks = 300
# Fail-safe. Time in seconds until the process is terminated no matter what.
$secondsUntilGiveUpMax = 86400

### opencast configuration end

#
# Parse TimeStamps - Start and End Time
#
# doc: file handle
#
# return: start and end time of the conference in ms (Unix EPOC)
#
def getRealStartEndTimes(doc)
  # Parse general time values | Stolen from bigbluebutton/record-and-playback/presentation/scripts/process/presentation.rb
  # Times in ms
  meeting_start = doc.xpath("//event")[0][:timestamp]
  meeting_end = doc.xpath("//event").last()[:timestamp]

  meeting_id = doc.at_xpath("//meeting")[:id]
  real_start_time = meeting_id.split('-').last
  real_end_time = (real_start_time.to_i + (meeting_end.to_i - meeting_start.to_i)).to_s

  real_start_time = real_start_time.to_i
  real_end_time = real_end_time.to_i

  return real_start_time, real_end_time
end

#
# Parse TimeStamps - All files and start times for a given event
#
# doc: file handle
# eventName: name of the xml tag attribute 'eventName', string
# resultArray: Where results will be appended to, array
# filePath: Path to the folder were the file related to the event will reside
#
# return: resultArray with appended hashes
#
def parseTimeStamps(doc, eventName, resultArray, filePath)
  doc.xpath("//event[@eventname='#{eventName}']").each do |item|
    newItem = Hash.new
    newItem["filename"] = item.at_xpath("filename").content.split('/').last
    newItem["timestamp"] = item.at_xpath("timestampUTC").content.to_i
    newItem["filepath"] = filePath
    if !File.exists?(File.join(newItem["filepath"], newItem["filename"]))
      next
    end
    resultArray.push(newItem)
  end

  return resultArray
end

#
# Parse TimeStamps - Recording marks start and stop
#
# doc: file handle
# eventName: name of the xml tag attribute 'eventName', string
# recordingStart: Where results will be appended to, array
# recordingStop: Where results will be appended to, array
#
# return: recordingStart, recordingStop arrays with timestamps
#
def parseTimeStampsRecording(doc, eventName, recordingStart, recordingStop, real_end_time)
  # Parse timestamps for Recording
  doc.xpath("//event[@eventname='#{eventName}']").each do |item|
    if item.at_xpath("status").content == "true"
      recordingStart.push(item.at_xpath("timestampUTC").content.to_i)
    else
      recordingStop.push(item.at_xpath("timestampUTC").content.to_i)
    end
  end

  if recordingStart.length > recordingStop.length
    recordingStop.push(real_end_time)
  end

  return recordingStart, recordingStop
end

#
# Parse TimeStamps - All files, start times and presentation for a given slide
#
# doc: file handle
# eventName: name of the xml tag attribute 'eventName', string
# resultArray: Where results will be appended to, array
# filePath: Path to the folder were the file related to the event will reside
#
# return: resultArray with appended hashes
#
def parseTimeStampsPresentation(doc, eventName, resultArray, filePath)
  doc.xpath("//event[@eventname='#{eventName}']").each do |item|
    newItem = Hash.new
    if(item.at_xpath("slide"))
      newItem["filename"] = "slide#{item.at_xpath("slide").content.to_i + 1}.svg" # Add 1 to fix index
    else
      newItem["filename"] = "slide1.svg"  # Assume slide 1
    end
    newItem["timestamp"] = item.at_xpath("timestampUTC").content.to_i
    newItem["filepath"] = File.join(filePath, item.at_xpath("presentationName").content, "svgs")
    newItem["presentationName"] = item.at_xpath("presentationName").content
    if !File.exists?(File.join(newItem["filepath"], newItem["filename"]))
      next
    end
    resultArray.push(newItem)
  end

  return resultArray
end

#
# Helper function for changing a filename string
#
def changeFileExtensionTo(filename, extension)
  return "#{File.basename(filename, File.extname(filename))}.#{extension}"
end

# def makeEven(number)
#   return number % 2 == 0 ? number : number + 1
# end

#
# Convert SVGs to MP4s
#
# SVGs are converted to PNGs first, since ffmpeg can to weird things with SVGs.
#
# presentationSlidesStart: array of numerics
#
# return: presentationSlidesStart, with filenames now pointing to the new videos
#
def convertSlidesToVideo(presentationSlidesStart)
  presentationSlidesStart.each do |item|
    # Path to original svg
    originalLocation = File.join(item["filepath"], item["filename"])
    # Save conversion with similar path in tmp
    dirname = File.join(TMP_PATH, item["presentationName"], "svgs")
    finalLocation = File.join(dirname, changeFileExtensionTo(item["filename"], "mp4"))

    if (!File.exists?(finalLocation))
      # Create path to save conversion to
      unless File.directory?(dirname)
        FileUtils.mkdir_p(dirname)
      end

      # Convert to png
      image = MiniMagick::Image.open(originalLocation)
      image.format 'png'
      pathToImage = File.join(dirname, changeFileExtensionTo(item["filename"], "png"))
      image.write pathToImage

      # Convert to video
      # Scales the output to be divisible by 2
      system "ffmpeg -loglevel quiet -nostdin -nostats -y -r 30 -i #{pathToImage} -vf crop='trunc(iw/2)*2:trunc(ih/2)*2' #{finalLocation}"
    end

    item["filepath"] = dirname
    item["filename"] = finalLocation.split('/').last
  end

  return presentationSlidesStart
end

#
# Checks if the video requires transcoding before sending it to Opencast
# * Checks if a video has a width and height that is divisible by 2
#   If not, crops the video to have one
# * Checks if the video is missing duration metadata
#   If it's missing, copies the video to add it
#
# path: string, path to the file in question (without the filename)
# filename: string, name of the file (with extension)
#
# return: new path to the file (keeps the filename)
#
def checkForTranscode(path, filename)
  pathToFile = File.join(path, filename)
  outputPathToFile = File.join(TMP_PATH, pathToFile)

  if ($doNotConvertVideosAgain && File.exists?(outputPathToFile))
    BigBlueButton.logger.info( "Converted video for #{pathToFile} already exists, skipping...")
    return path
  end

  # Gather possible commands
  transcodeCommands = []
  movie = FFMPEG::Movie.new(pathToFile)
  unless (movie.width % 2 == 0 && movie.height % 2 == 0)
    BigBlueButton.logger.info( "Video #{pathToFile} requires cropping to be DivBy2")
    transcodeCommands.push(%w(-y -r 30 -vf crop=trunc(iw/2)*2:trunc(ih/2)*2))
  end
  if (movie.duration <= 0)
    BigBlueButton.logger.info( "Video #{pathToFile} requires transcoding due to missing duration")
    transcodeCommands.push(%w(-y -c copy))
  end

  # Run gathered commands
  if(transcodeCommands.length == 0)
    BigBlueButton.logger.info( "Video #{pathToFile} is fine")
    return path
  else
    # Create path to save conversion to
    outputPath = File.join(TMP_PATH, path)
    unless File.directory?(outputPath)
      FileUtils.mkdir_p(outputPath)
    end

    BigBlueButton.logger.info( "Start converting #{pathToFile} ...")
    transcodeCommands.each do | command |
      BigBlueButton.logger.info( "Running ffmpeg with options: #{command}")
      movie.transcode(outputPath + 'tmp' + filename, command)
      FileUtils.mv(outputPath + 'tmp' + filename, outputPathToFile)
      movie = FFMPEG::Movie.new(outputPathToFile)   # Further transcoding should happen on the new file
    end

    BigBlueButton.logger.info( "Done converting #{pathToFile}")
    return outputPath
  end
end

#
# Collect file information
#
# tracks: Structure containing information on each file, array of hashes
# flavor: Whether the file is part of presenter or presentation, string
# startTimes: When each file was started to be recorded in ms, array of numerics
# real_start_time: Starting timestamp of the conference
#
# return: tracks + new tracks found at directory_path
#

def collectFileInformation(tracks, flavor, startTimes, real_start_time)
  startTimes.each do |file|
    pathToFile = File.join(file["filepath"], file["filename"])

    BigBlueButton.logger.info( "PathToFile: #{pathToFile}")

    if (File.exists?(pathToFile))
      # File Integrity check
      if (!FFMPEG::Movie.new(pathToFile).valid?)
        BigBlueButton.logger.info( "The file #{pathToFile} is ffmpeg-invalid and won't be ingested")
        next
      end

      tracks.push( { "flavor": flavor,
                    "startTime": file["timestamp"] - real_start_time,
                    "path": pathToFile
      } )
    end
  end

  return tracks
end

#
# Creates a JSON for sending cutting marks
#
# path: Location to save JSON to, string
# recordingStart: Start marks, array
# recordingStop: Stop marks, array
# real_start_time: Start time of the conference
# real_end_time: End time of the conference
#
def createCuttingMarksJSONAtPath(path, recordingStart, recordingStop, real_start_time, real_end_time)
  tmpTimes = []

  index = 0
  recordingStart.each do |startStamp|
    stopStamp = recordingStop[index]

    tmpTimes.push( {
      "begin" => startStamp - real_start_time,
      "duration" => stopStamp - startStamp
    } )
    index += 1
  end

  File.write(path, JSON.pretty_generate(tmpTimes))
end

#
# Sends a web request to Opencast, using the credentials defined at the top
#
# method: Http method, symbol (e.g. :get, :post)
# url: ingest method, string (e.g. '/ingest/addPartialTrack')
# timeout: seconds until request returns with a timeout, numeric
# payload: information necessary for the request, hash
#
# return: The web request response
#
def requestIngestAPI(method, url, timeout, payload, additionalErrorMessage="")
  begin
    response = RestClient::Request.new(
      :method => method,
      :url => $oc_server + url,
      :user => $oc_user,
      :password => $oc_password,
      :timeout => timeout,
      :payload => payload
    ).execute
  rescue RestClient::Exception => e
    BigBlueButton.logger.error(" A problem occured for request: #{url}")
    BigBlueButton.logger.info( e)
    BigBlueButton.logger.info( e.http_body)
    BigBlueButton.logger.info( additionalErrorMessage)
    exit 1
  end

  return response
end

#
# Helper function that determines if the metadata in question exists
#
# metadata: hash (string => string)
# metadata_name: string, the key we hope exists in metadata
# fallback: object, what to return if it doesn't (or is empty)
#
# return: the value corresponding to metadata_name or fallback
#
def parseMetadataFieldOrFallback(metadata, metadata_name, fallback)
  return !(metadata[metadata_name.downcase].to_s.empty?) ?
           metadata[metadata_name.downcase] : fallback
end

#
# Creates a definition for metadata, containing symbol, identifier and fallback
#
# metadata: hash (string => string)
# meetingStartTime: time, as a fallback for the "created" metadata-field
#
# return: array of hashes
#
def getDcMetadataDefinition(metadata, meetingStartTime, meetingEndTime)
  dc_metadata_definition = []
  dc_metadata_definition.push( { :symbol   => :title,
                                 :fullName => "opencast-dc-title",
                                 :fallback => metadata['meetingname']})
  dc_metadata_definition.push( { :symbol   => :identifier,
                                 :fullName => "opencast-dc-identifier",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :creator,
                                 :fullName => "opencast-dc-creator",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :isPartOf,
                                 :fullName => "opencast-dc-ispartof",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :contributor,
                                 :fullName => "opencast-dc-contributor",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :subject,
                                 :fullName => "opencast-dc-subject",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :language,
                                 :fullName => "opencast-dc-language",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :description,
                                 :fullName => "opencast-dc-description",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :spatial,
                                 :fullName => "opencast-dc-spatial",
                                 :fallback => "BigBlueButton"})
  dc_metadata_definition.push( { :symbol   => :created,
                                 :fullName => "opencast-dc-created",
                                 :fallback => meetingStartTime})
  dc_metadata_definition.push( { :symbol   => :rightsHolder,
                                 :fullName => "opencast-dc-rightsholder",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :license,
                                 :fullName => "opencast-dc-license",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :publisher,
                                 :fullName => "opencast-dc-publisher",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :temporal,
                                 :fullName => "opencast-dc-temporal",
                                 :fallback => "start=#{Time.at(meetingStartTime / 1000).to_datetime};
                                               end=#{Time.at(meetingEndTime / 1000).to_datetime};
                                               scheme=W3C-DTF"})
  dc_metadata_definition.push( { :symbol   => :source,
                                 :fullName => "opencast-dc-source",
                                 :fallback => $passIdentifierAsDcSource ?
                                              metadata["opencast-dc-identifier"] : nil })
  return dc_metadata_definition
end

#
# Creates a definition for metadata, containing symbol, identifier and fallback
#
# metadata: hash (string => string)
# meetingStartTime: time, as a fallback for the "created" metadata-field
#
# return: array of hashes
#
def getSeriesDcMetadataDefinition(metadata, meetingStartTime)
  dc_metadata_definition = []
  dc_metadata_definition.push( { :symbol   => :title,
                                 :fullName => "opencast-series-dc-title",
                                 :fallback => metadata['meetingname']})
  dc_metadata_definition.push( { :symbol   => :identifier,
                                 :fullName => "opencast-dc-isPartOf",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :creator,
                                 :fullName => "opencast-series-dc-creator",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :contributor,
                                 :fullName => "opencast-series-dc-contributor",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :subject,
                                 :fullName => "opencast-series-dc-subject",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :language,
                                 :fullName => "opencast-series-dc-language",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :description,
                                 :fullName => "opencast-series-dc-description",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :rightsHolder,
                                 :fullName => "opencast-series-dc-rightsholder",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :license,
                                 :fullName => "opencast-series-dc-license",
                                 :fallback => nil})
  dc_metadata_definition.push( { :symbol   => :publisher,
                                 :fullName => "opencast-series-dc-publisher",
                                 :fallback => nil})
  return dc_metadata_definition
end

#
# Parses dublincore-relevant information from the metadata
# Contains the definitions for metadata-field-names
# Casts metadata keys to LOWERCASE
#
# metadata: hash (string => string)
#
# return hash (symbol => object)
#
def parseDcMetadata(metadata, dc_metadata_definition)
  dc_data = {}

  dc_metadata_definition.each do |definition|
    dc_data[definition[:symbol]] = parseMetadataFieldOrFallback(metadata, definition[:fullName], definition[:fallback])
  end

  return dc_data
end

#
# Checks if the given identifier is valid to be used for an Opencast event
#
# identifier: string, to be used as the UID for an Opencast event
#
# Returns the identifier if it is valid, nil if not
#
def checkEventIdentifier(identifier)
  # Check for nil & empty
  if identifier.to_s.empty?
    return nil
  end

  # Check for UUID conformity
  uuid_regex = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  if !(identifier.to_s.downcase =~ uuid_regex)
    BigBlueButton.logger.info( "The given identifier <#{identifier}> is not a valid UUID. Will be using generated UUID instead.")
    return nil
  end

  # Check for existence in Opencast
  existsInOpencast = true
  begin
    response = RestClient::Request.new(
      :method => :get,
      :url => $oc_server + "/api/events/" + identifier,
      :user => $oc_user,
      :password => $oc_password,
    ).execute
  rescue RestClient::Exception => e
    existsInOpencast = false
  end
  if existsInOpencast
    BigBlueButton.logger.info( "The given identifier <#{identifier}> already exists within Opencast. Will be using generated UUID instead.")
    return nil
  end

  return identifier
end

#
# Returns the metadata tags defined for user access list
#
# return: hash
#
def getAclMetadataDefinition()
  return {:readRoles => "opencast-acl-read-roles",
          :writeRoles => "opencast-acl-write-roles",
          :userIds => "opencast-acl-user-id"}
end

#
# Returns the metadata tags defined for series access list
#
# return: hash
#
def getSeriesAclMetadataDefinition()
  return {:readRoles => "opencast-series-acl-read-roles",
          :writeRoles => "opencast-series-acl-write-roles",
          :userIds => "opencast-series-acl-user-id"}
end

#
# Parses acl-relevant information from the metadata
#
# metadata: hash (string => string)
#
# return array of hash (symbol => string, symbol => string)
#
def parseAclMetadata(metadata, acl_metadata_definition, defaultReadRoles, defaultWriteRoles)
  acl_data = []

  # Read from global, configured-by-user variable
  defaultReadRoles.to_s.split(",").each do |role|
    acl_data.push( { :user => role, :permission => "read" } )
  end
  defaultWriteRoles.to_s.split(",").each do |role|
    acl_data.push( { :user => role, :permission => "write" } )
  end

  # Read from Metadata
  metadata[acl_metadata_definition[:readRoles]].to_s.split(",").each do |role|
    acl_data.push( { :user => role, :permission => "read" } )
  end
  metadata[acl_metadata_definition[:writeRoles]].to_s.split(",").each do |role|
    acl_data.push( { :user => role, :permission => "write" } )
  end

  metadata[acl_metadata_definition[:userIds]].to_s.split(",").each do |userId|
    acl_data.push( { :user => "ROLE_USER_#{userId}", :permission => "read" } )
    acl_data.push( { :user => "ROLE_USER_#{userId}", :permission => "write" } )
  end

  return acl_data
end

#
# Creates a xml using the given role information
#
# roles: array of hash (symbol => string, symbol => string), containing user role and permission
#
# returns: string, the xml
#
def createAcl(roles)
  header = Nokogiri::XML('<?xml version = "1.0" encoding = "UTF-8" standalone ="yes"?>')
  builder = Nokogiri::XML::Builder.with(header) do |xml|
    xml.Policy('PolicyId' => 'mediapackage-1',
    'RuleCombiningAlgId' => 'urn:oasis:names:tc:xacml:1.0:rule-combining-algorithm:permit-overrides',
    'Version' => '2.0',
    'xmlns' => 'urn:oasis:names:tc:xacml:2.0:policy:schema:os') {
      roles.each do |role|
        xml.Rule('RuleId' => "#{role[:user]}_#{role[:permission]}_Permit", 'Effect' => 'Permit') {
          xml.Target {
            xml.Actions {
              xml.Action {
                xml.ActionMatch('MatchId' => 'urn:oasis:names:tc:xacml:1.0:function:string-equal') {
                  xml.AttributeValue('DataType' => 'http://www.w3.org/2001/XMLSchema#string') { xml.text(role[:permission]) }
                  xml.ActionAttributeDesignator('AttributeId' => 'urn:oasis:names:tc:xacml:1.0:action:action-id',
                  'DataType' => 'http://www.w3.org/2001/XMLSchema#string')
                }
              }
            }
          }
          xml.Condition{
            xml.Apply('FunctionId' => 'urn:oasis:names:tc:xacml:1.0:function:string-is-in') {
              xml.AttributeValue('DataType' => 'http://www.w3.org/2001/XMLSchema#string') { xml.text(role[:user]) }
              xml.SubjectAttributeDesignator('AttributeId' => 'urn:oasis:names:tc:xacml:2.0:subject:role',
              'DataType' => 'http://www.w3.org/2001/XMLSchema#string')
            }
          }
        }
      end
    }
  end

  return builder.to_xml
end

#
# Creates a xml using the given role information
#
# roles: array of hash (symbol => string, symbol => string), containing user role and permission
#
# returns: string, the xml
#
def createSeriesAcl(roles)
  header = Nokogiri::XML('<?xml version = "1.0" encoding = "UTF-8" standalone ="yes"?>')
  builder = Nokogiri::XML::Builder.with(header) do |xml|
    xml.acl('xmlns' => 'http://org.opencastproject.security') {
      roles.each do |role|
        xml.ace {
          xml.action { xml.text(role[:permission]) }
          xml.allow { xml.text('true') }
          xml.role { xml.text(role[:user]) }
        }
      end
    }
  end

  return builder.to_xml
end

#
# Recursively check if 2 Nokogiri nodes are the same
# Does not check for attributes
#
# node1: The first Nokogiri node
# node2: The second Nokogori node
#
# returns: boolean, true if the nodes are equal
#
def sameNodes?(node1, node2, truthArray=[])
	if node1.nil? || node2.nil?
		return false
	end
	if node1.name != node2.name
		return false
	end
  if node1.text != node2.text
          return false
  end
	node1Attrs = node1.attributes
	node2Attrs = node2.attributes
	node1Kids = node1.children
	node2Kids = node2.children
	node1Kids.zip(node2Kids).each do |pair|
		truthArray << sameNodes?(pair[0],pair[1])
	end
	# if every value in the array is true, then the nodes are equal
	return truthArray.all?
end

#
# Extends a series ACL with given roles, if those roles are not already part of the ACL
#
# xml: A parsable xml string
# roles: array of hash (symbol => string, symbol => string), containing user role and permission
#
# returns:
#
def updateSeriesAcl(xml, roles)

  doc = Nokogiri::XML(xml)
  newNodeSet = Nokogiri::XML::NodeSet.new(doc)

  roles.each do |role|
    newNode = nokogiri_node_creator(doc, "ace", "")
    newNode << nokogiri_node_creator(doc, "action", role[:permission])
    newNode <<  nokogiri_node_creator(doc, "allow", 'true')
    newNode <<  nokogiri_node_creator(doc, "role", role[:user])

    # Avoid adding duplicate nodes
    nodeAlreadyExists = false
    doc.xpath("//x:ace", "x" => "http://org.opencastproject.security").each do |oldNode|
      if sameNodes?(oldNode, newNode)
        nodeAlreadyExists = true
        break
      end
    end

    if (!nodeAlreadyExists)
      newNodeSet << newNode
    end
  end

  doc.root << newNodeSet

  return doc.to_xml
end

#
# Will create a new series with the given Id, if such a series does not yet exist
# Else will try to update the ACL of the series
#
# createSeriesId: string, the UID for the new series
#
def createSeries(createSeriesId, meeting_metadata, real_start_time)
  BigBlueButton.logger.info( "Attempting to create a new series...")
  # Check if a series with the given identifier does already exist
  seriesExists = false
  seriesFromOc = requestIngestAPI(:get, '/series/allSeriesIdTitle.json', DEFAULT_REQUEST_TIMEOUT, {})
  begin
    seriesFromOc = JSON.parse(seriesFromOc)
    seriesFromOc["series"].each do |serie|
      BigBlueButton.logger.info( "Found series: " + serie["identifier"].to_s)
      if (serie["identifier"].to_s === createSeriesId.to_s)
        seriesExists = true
        BigBlueButton.logger.info( "Series already exists")
        break
      end
    end
  rescue JSON::ParserError  => e
    BigBlueButton.logger.warn(" Could not parse series JSON, Exception #{e}")
  end

  # Create Series
  if (!seriesExists)
    BigBlueButton.logger.info( "Create a new series with ID " + createSeriesId)
    # Create Series-DC
    seriesDcData = parseDcMetadata(meeting_metadata, getSeriesDcMetadataDefinition(meeting_metadata, real_start_time))
    seriesDublincore = createDublincore(seriesDcData)
    # Create Series-ACL
    seriesAcl = createSeriesAcl(parseAclMetadata(meeting_metadata, getSeriesAclMetadataDefinition(),
                  $defaultSeriesRolesWithReadPerm, $defaultSeriesRolesWithWritePerm))
    BigBlueButton.logger.info( "seriesAcl: " + seriesAcl.to_s)

    requestIngestAPI(:post, '/series/', DEFAULT_REQUEST_TIMEOUT,
    { :series => seriesDublincore,
      :acl => seriesAcl,
      :override => false})

  # Update Series ACL
  else
    BigBlueButton.logger.info( "Updating series ACL...")
    seriesAcl = requestIngestAPI(:get, '/series/' + createSeriesId + '/acl.xml', DEFAULT_REQUEST_TIMEOUT, {})
    roles = parseAclMetadata(meeting_metadata, getSeriesAclMetadataDefinition(), $defaultSeriesRolesWithReadPerm, $defaultSeriesRolesWithWritePerm)

    if (roles.length > 0)
      updatedSeriesAcl = updateSeriesAcl(seriesAcl, roles)
      requestIngestAPI(:post, '/series/' + createSeriesId + '/accesscontrol', DEFAULT_REQUEST_TIMEOUT,
        { :acl => updatedSeriesAcl,
          :override => false})
      BigBlueButton.logger.info( "Updated series ACL")
    else
      BigBlueButton.logger.info( "Nothing to update ACL with")
    end
  end
end

#
# Parses the chat messages from the events.xml into a webvtt subtitles file
# TODO: Sanitize chat messages?
#
# doc: file handle
# chatFilePath: string
# realStartTime: number, start time of the meeting in epoch time
# recordingStart: array[string], times when the recording button was pressed in epoch time
# recordingStop: array[string], times when the recording button was pressed in epoch time
#
def parseChat(doc, chatFilePath, realStartTime, recordingStart, recordingStop)
  BigBlueButton.logger.info( "Parsing chat messages")

  timeFormat = '%H:%M:%S.%L'
  displayMessageTimeMax = 3  # seconds
  chatMessages = []

  # Gather messages
  chatEvents = doc.xpath("//event[@eventname='PublicChatEvent']")

  recordingStart.each.with_index do |recordStartStamp, index|
    recordStopStamp = recordingStop[index]

    chatEvents.each do |node|
      chatTimestamp = node.at_xpath("timestampUTC").content.to_i

      if (chatTimestamp >= recordStartStamp.to_i and chatTimestamp <= recordStopStamp.to_i)
        chatSender = node.xpath(".//sender")[0].text()
        chatMessage =  node.xpath(".//message")[0].text()
        chatStart = Time.at((chatTimestamp - realStartTime) / 1000.0) #.utc.strftime(TIME_FORMAT)
        #chatEnd = Time.at((chatTimestamp - realStartTime) / 1000.0) + 2
        #chatEnd = chatEnd.utc.strftime(TIME_FORMAT)
        chatMessages.push({sender: chatSender,
          message: chatMessage,
          startTime: chatStart,
          endTime: Time.at(0)
        })
      end
    end

  end

  # Update timestamps
  chatMessages.each.with_index do |message, index|
    # Last message
    if chatMessages[index + 1].nil?
      message[:endTime] = message[:startTime] + displayMessageTimeMax
      break
    end

    if (chatMessages[index + 1][:startTime] - message[:startTime]) < displayMessageTimeMax
      message[:endTime] = chatMessages[index + 1][:startTime]
    else
      message[:endTime] = message[:startTime] + displayMessageTimeMax
    end
  end

  # Compile messages
  files = []
  files.push("WEBVTT")
  files.push("")
  chatMessages.each do |message|
    files.push(message[:startTime].utc.strftime(timeFormat).to_s + " --> " + message[:endTime].utc.strftime(timeFormat).to_s)
    files.push(message[:sender] + ": " + message[:message])
    files.push("")
  end

  if (chatMessages.length > 0)
    File.write(chatFilePath, files.join("\n"))
  end
end

#
# Monitors the state of the started workflow after ingest
# Will run for quite some time
#
def monitorOpencastWorkflow(ingestResponse, secondsBetweenChecks, secondsUntilGiveUpMax, meetingId)

  ### Wait for Opencast to be done
  secondsUntilGiveUpCounter = 0
  isOpencastDoneYet = false

  # Get the id of the workflow
  doc = Nokogiri::XML(ingestResponse)
  workflowID = doc.xpath("//wf:workflow")[0].attr('id')
  mediapackageID = doc.xpath("//mp:mediapackage")[0].attr('id')

  # Keep checking whether the started workflow is still running or not
  while !isOpencastDoneYet do
    # Wait between checks
    sleep(secondsBetweenChecks)

    # Request check
    response = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                :get, '/workflow/instance/' + workflowID + '.xml', DEFAULT_REQUEST_TIMEOUT, {},
                "There has been a problem in OC with the workflow for mediapackage " + mediapackageID + " for BBB recording " + meetingId + ". Aborting..." )

    # Request workflow information
    doc = Nokogiri::XML(response)
    elems = doc.xpath("//wf:workflow")
    state = elems[0].attr('state')

    # Check state
    if (state == "SUCCEEDED")
      BigBlueButton.logger.info( "Workflow for " + mediapackageID + " succeeded.")
      isOpencastDoneYet = true
    elsif (state == "RUNNING" || state == "INSTANTIATED")
      BigBlueButton.logger.info( "Workflow for " + mediapackageID + " is " + state)
    else
      BigBlueButton.logger.error(" Workflow for " + mediapackageID + " is in state + " + state + ", meaning it is neither running nor has it succeeded. Recording data for " + meetingId + " will not be cleaned up. Aborting...")
      exit 1
    end

    # Fail-safe. End this process after some time has passed.
    secondsUntilGiveUpCounter += secondsBetweenChecks
    if ( secondsUntilGiveUpCounter >= secondsUntilGiveUpMax )
      BigBlueButton.logger.error(" " + secondsUntilGiveUpMax.to_s + " seconds have passed since the mediapackage with id " + mediapackageID + " was ingested. Mercy killing process for recording " + meeting_id)
      exit 1
    end

  end
end

#
# Anything and everything that should be done just before the program successfully terminates for any reason
#
# tmp_path: string, path to local temporary directory
# meeting_id: numeric, id of the current meeting
#
def cleanup(tmp_path, meeting_id)
  # Delete temporary files
  FileUtils.rm_rf(tmp_path)

  # Delete all raw recording data
  # TODO: Find a way to outsource this into a script that runs after all post_archive scripts have run successfully
  system('sudo', 'bbb-record', '--delete', "#{meeting_id}") || raise('Failed to delete local recording')
end

#########################################################
################## START ################################
#########################################################

### Initialization begin

#
# Parse cmd args from BBB and initialize logger

opts = Trollop::options do
  opt :meeting_id, "Meeting id to archive", :type => String
end
meeting_id = opts[:meeting_id]

logger = Logger.new("/var/log/bigbluebutton/post_archive.log", 'weekly' )
logger.level = Logger::INFO
BigBlueButton.logger = logger

archived_files = "/var/bigbluebutton/recording/raw/#{meeting_id}"
meeting_metadata = BigBlueButton::Events.get_meeting_metadata("#{archived_files}/events.xml")
xml_path = archived_files +"/events.xml"
BigBlueButton.logger.info("Series id: #{meeting_metadata["opencast-series-id"]}")

# Variables
mediapackage = ''
deskshareStart = []           # Array of timestamps
webcamStart = []              # Array of hashes[filename, timestamp]
audioStart = []               # Array of hashes[filename, timestamp]
recordingStart = []           # Array of timestamps
recordingStop = []            # Array of timestamps
presentationSlidesStart = []  # Array of hashes[filename, timestamp, presentationName]
tracks = []                   # Array of hashes[flavor, starttime, path]

# Constants
DEFAULT_REQUEST_TIMEOUT = 10                                  # Http request timeout in seconds
START_WORKFLOW_REQUEST_TIMEOUT = 6000                         # Specific timeout; Opencast runs MediaInspector on every file, which can take quite a while
CUTTING_MARKS_FLAVOR = "json/times"

VIDEO_PATH = File.join(archived_files, 'video', meeting_id)    # Path defined by BBB
AUDIO_PATH = File.join(archived_files, 'audio')                # Path defined by BBB
DESKSHARE_PATH = File.join(archived_files, 'deskshare')        # Path defined by BBB
PRESENTATION_PATH = File.join(archived_files, 'presentation')  # Path defined by BBB
SHARED_NOTES_PATH = File.join(archived_files, 'notes')         # Path defined by BBB
TMP_PATH = File.join(archived_files, 'upload_tmp')             # Where temporary files can be stored
CUTTING_JSON_PATH = File.join(TMP_PATH, "cutting.json")
CHAT_PATH = File.join(TMP_PATH, "chat.vtt")
ACL_PATH = File.join(TMP_PATH, "acl.xml")

# Create local tmp directory
unless File.directory?(TMP_PATH)
  FileUtils.mkdir_p(TMP_PATH)
end

# Convert metadata keys to lowercase
# Transform_Keys is only available from ruby 2.5 onward :(
#metadata = metadata.transform_keys(&:downcase)
tmp_metadata = {}
meeting_metadata.each do |key, value|
  tmp_metadata["#{key.downcase}"] = meeting_metadata.delete("#{key}")
end
meeting_metadata = tmp_metadata

### Initialization end

#
# Parse TimeStamps
#

# Get events file handle
doc = ''
if(File.file?(xml_path))
  doc = Nokogiri::XML(File.open(xml_path))
else
  BigBlueButton.logger.error(": NO EVENTS.XML for recording" + meeting_id + "! Nothing to parse, aborting...")
  exit 1
end

# Get conference start and end timestamps in ms
real_start_time, real_end_time = getRealStartEndTimes(doc)
# Get screen share start timestamps
deskshareStart = parseTimeStamps(doc, 'StartWebRTCDesktopShareEvent', deskshareStart, DESKSHARE_PATH)
# Get webcam share start timestamps
webcamStart = parseTimeStamps(doc, 'StartWebRTCShareEvent', webcamStart, VIDEO_PATH)
# Get audio recording start timestamps
audioStart = parseTimeStamps(doc, 'StartRecordingEvent', audioStart, AUDIO_PATH)
# Get cut marks
recordingStart, recordingStop = parseTimeStampsRecording(doc, 'RecordStatusEvent', recordingStart, recordingStop, real_end_time)
# Get presentation slide start stamps
presentationSlidesStart = parseTimeStampsPresentation(doc, 'SharePresentationEvent', presentationSlidesStart, PRESENTATION_PATH) # Grab a timestamp for the beginning
presentationSlidesStart = parseTimeStampsPresentation(doc, 'GotoSlideEvent', presentationSlidesStart, PRESENTATION_PATH) # Grab timestamps from Goto events

# Opencasts addPartialTrack cannot handle files without a duration,
# therefore images need to be converted to videos.
presentationSlidesStart = convertSlidesToVideo(presentationSlidesStart)

# Check and process any videos if they need to be prepared before Opencast can process them
deskshareStart.each do |share|
  share["filepath"] = checkForTranscode(share["filepath"], share["filename"])
end
webcamStart.each do |share|
  share["filepath"] = checkForTranscode(share["filepath"], share["filename"])
end

# Exit program if the recording was not pressed
if ($onlyIngestIfRecordButtonWasPressed && recordingStart.length == 0)
  BigBlueButton.logger.info( "Recording Button was not pressed, aborting...")
  cleanup(TMP_PATH, meeting_id)
  exit 0
# Or instead assume that everything should be recorded
elsif (!$onlyIngestIfRecordButtonWasPressed && recordingStart.length == 0)
  recordingStart.push(real_start_time)
  recordingStop.push(real_end_time)
end

#
# Prepare information to be send to Opencast
# Tracks are ingested on a per file basis, so iterate through all files that should be send
#

# Add webcam tracks
# Exception: Once Opencast can handle multiple webcam files, this can be replaced by a collectFileInformation call
webcamStart.each do |file|
  if (File.exists?(File.join(file["filepath"], file["filename"])))
    # File Integrity check
    if (!FFMPEG::Movie.new(File.join(file["filepath"], file["filename"])).valid?)
      BigBlueButton.logger.info( "The file #{File.join(file["filepath"], file["filename"])} is ffmpeg-invalid and won't be ingested")
      continue
    end
    tracks.push( { "flavor": 'presenter/source',
                   "startTime": file["timestamp"] - real_start_time,
                   "path": File.join(file["filepath"], file["filename"])
    } )
    break   # Stop after first iteration to only send first webcam file found. TODO: Teach Opencast to deal with webcam files
  end
end
# Add audio tracks (Likely to be only one track)
tracks = collectFileInformation(tracks, 'presentation/source', audioStart, real_start_time)
# Add screen share tracks
tracks = collectFileInformation(tracks, 'presentation/source', deskshareStart, real_start_time)
# Add the previously generated tracks for presentation slides
tracks = collectFileInformation(tracks, 'presentation/source', presentationSlidesStart, real_start_time)

if(tracks.length == 0)
  BigBlueButton.logger.warn(" There are no files, nothing to do here")
  cleanup(TMP_PATH, meeting_id)
  exit 0
end

# Sort tracks in ascending order by their startTime, as is required by PartialImportWOH
tracks = tracks.sort_by { |k| k[:startTime] }
BigBlueButton.logger.info( "Sorted tracks: ")
BigBlueButton.logger.info( tracks)

# Create metadata file dublincore
dc_data = OcDublincore::parseDcMetadata(meeting_metadata, server: $oc_server, user: $oc_user, password: $oc_password)
dublincore = OcDublincore::createDublincore(dc_data)
BigBlueButton.logger.info( "Dublincore: \n" + dublincore.to_s)

# Create Json containing cutting marks at path
createCuttingMarksJSONAtPath(CUTTING_JSON_PATH, recordingStart, recordingStop, real_start_time, real_end_time)

# Create ACLs at path
aclData = OcAcl::parseEpisodeAclMetadata(meeting_metadata, $defaultRolesWithReadPerm, $defaultRolesWithWritePerm)
if (!aclData.nil? && !aclData.empty?)
  File.write(ACL_PATH, OcAcl::createAcl(aclData))
end

# Create series with given seriesId, if such a series does not yet exist
if ($createNewSeriesIfItDoesNotYetExist)
  OcAcl::createSeries(meeting_metadata, $oc_server, $oc_user, $oc_password, $defaultSeriesRolesWithReadPerm, $defaultSeriesRolesWithWritePerm)
end

# Create a subtitles file from chat
if ($sendChatAsSubtitleAttachment)
  parseChat(doc, CHAT_PATH, real_start_time, recordingStart, recordingStop)
end

#
# Create a mediapackage and ingest it
#

# Create Mediapackage
if !dc_data[:identifier].to_s.empty?
  mediapackage = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                  :put, '/ingest/createMediaPackageWithID/' + dc_data[:identifier], DEFAULT_REQUEST_TIMEOUT,{})
else
  mediapackage = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                  :get, '/ingest/createMediaPackage', DEFAULT_REQUEST_TIMEOUT, {})
end
BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
# Get mediapackageId for debugging
doc = Nokogiri::XML(mediapackage)
mediapackageId = doc.xpath("/*")[0].attr('id')
# Add Partial Track
tracks.each do |track|
  BigBlueButton.logger.info( "Track: " + track.to_s)
  mediapackage = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                  :post, '/ingest/addPartialTrack', DEFAULT_REQUEST_TIMEOUT,
                  { :flavor => track[:flavor],
                    :startTime => track[:startTime],
                    :mediaPackage => mediapackage,
                    :body => File.open(track[:path], 'rb') })
  BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
end
# Add dublincore
mediapackage = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                :post, '/ingest/addDCCatalog', DEFAULT_REQUEST_TIMEOUT,
                {:mediaPackage => mediapackage,
                 :dublinCore => dublincore })
BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
# Add cutting marks
mediapackage = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                :post, '/ingest/addCatalog', DEFAULT_REQUEST_TIMEOUT,
                {:mediaPackage => mediapackage,
                 :flavor => CUTTING_MARKS_FLAVOR,
                 :body => File.open(CUTTING_JSON_PATH, 'rb')})
                 #:body => File.open(File.join(archived_files, "cutting.json"), 'rb')})

BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
# Add ACL
if (File.file?(ACL_PATH))
  mediapackage = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                  :post, '/ingest/addAttachment', DEFAULT_REQUEST_TIMEOUT,
                  {:mediaPackage => mediapackage,
                  :flavor => "security/xacml+episode",
                  :body => File.open(ACL_PATH, 'rb') })
  BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
else
  BigBlueButton.logger.info( "No ACL found, skipping adding ACL.")
end
# Add Shared Notes
if ($sendSharedNotesEtherpadAsAttachment && File.file?(File.join(SHARED_NOTES_PATH, "notes.etherpad")))
  mediapackage = requestIngestAPI(:post, '/ingest/addCatalog', DEFAULT_REQUEST_TIMEOUT,
                  {:mediaPackage => mediapackage,
                  :flavor => "etherpad/sharednotes",
                  :body => File.open(File.join(SHARED_NOTES_PATH, "notes.etherpad"), 'rb') })
  BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
else
  BigBlueButton.logger.info( "Adding Shared notes is either disabled or the etherpad was not found, skipping adding Shared Notes Etherpad.")
end
# Add Chat as subtitles
if ($sendChatAsSubtitleAttachment && File.file?(CHAT_PATH))
  mediapackage = requestIngestAPI(:post, '/ingest/addCatalog', DEFAULT_REQUEST_TIMEOUT,
                  {:mediaPackage => mediapackage,
                  :flavor => "captions/vtt+en",
                  :body => File.open(CHAT_PATH, 'rb') })
  BigBlueButton.logger.info( "Mediapackage: \n" + mediapackage)
else
  BigBlueButton.logger.info( "Adding Chat as subtitles is either disabled or there was no chat, skipping adding Chat as subtitles.")
end
# Ingest and start workflow
response = OcUtil::requestIngestAPI($oc_server, $oc_user, $oc_password,
                :post, '/ingest/ingest/' + $oc_workflow, START_WORKFLOW_REQUEST_TIMEOUT,
                { :mediaPackage => mediapackage },
                "LOG ERROR Aborting ingest with BBB id " + meeting_id + "and OC id" + mediapackageId )
BigBlueButton.logger.info( response)

### Monitor Opencast
if $monitorOpencastAfterIngest
  monitorOpencastWorkflow(response, $secondsBetweenChecks, $secondsUntilGiveUpMax, meeting_id)
end

### Exit gracefully
cleanup(TMP_PATH, meeting_id)
exit 0
