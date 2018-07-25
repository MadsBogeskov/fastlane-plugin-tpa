require 'fastlane/action'
require_relative '../helper/upload_symbols_to_tpa_helper'

module Fastlane
  module Actions
    class UploadSymbolsToTpaAction < Action
      def self.run(params)
        require 'digest/md5'
        require 'rest_client'

        # Params - dSYM
        dsym_paths = []
        dsym_paths << params[:dsym_path] if params[:dsym_path]
        dsym_paths += Actions.lane_context[SharedValues::DSYM_PATHS] if Actions.lane_context[SharedValues::DSYM_PATHS]

        if dsym_paths.count == 0
          UI.error("Couldn't find any dSYMs, please pass them using the dsym_path option")
          return nil
        end

        # Get rid of duplicate dSYMs (which might occur when both passed and detected)
        dsym_paths = dsym_paths.collect { |a| File.expand_path(a) }
        dsym_paths.uniq!

        # Fetches a list of dSYM files already uploaded to TPA
        known_dsyms = download_known_dsyms(params)

        # Handles each dSYM file
        dsym_paths.each do |current_path|
          if should_upload_dsym(params, known_dsyms, current_path)
            upload_dsym(params, current_path)
          else
            UI.message("Already uploaded: '#{current_path}'")
          end
        end

        UI.success("Successfully uploaded dSYM files to TPA 🎉")
      end

      def self.download_known_dsyms(params)
        UI.message("Downloading list of dSYMs already uploaded to TPA...")

        tpa_host = Helper::UploadSymbolsToTpaHelper.tpa_host(params)
        api_uuid = Helper::UploadSymbolsToTpaHelper.api_uuid(params)
        app_identifier = Helper::UploadSymbolsToTpaHelper.app_identifier(params)
        url = "#{tpa_host}/rest/api/v2/projects/#{api_uuid}/apps/#{app_identifier}/symbols/"

        begin
          res = RestClient.get(url, { :"X-API-Key" => params[:api_key] })
          result = JSON.parse(res.body)
        rescue => ex
          raise ex
        end
        return result
      end

      # Checks whether the given dsym path already exists in the list of known_dsyms
      def self.should_upload_dsym(params, known_dsyms, path)
        meta_data = parse_meta_data(path)

        # Constructs the dictionary to compare
        dict = {
          'filename' => File.basename(path),
          'version_number' => meta_data[:build],
          'version_string' => meta_data[:version],
          'hash' => Digest::MD5.hexdigest(File.read(path))
        }

        has_already_been_uploaded = known_dsyms.include?(dict)
        return !has_already_been_uploaded
      end

      # Parses the app identifier, version and build number from the dSYM path
      def self.parse_meta_data(path)
        # Extracts the app_identifier, version and build number from the path
        match_groups = File.basename(path).match("^(?<app_identifier>.+)-(?<version>.+)-(?<build>.+).dSYM.zip$")
        if match_groups.nil?
          raise "Failed to extract app identifier, version and build number from the #{path}"
        end
        return match_groups
      end

      # Uploads the given dsym path to TPA
      def self.upload_dsym(params, path)
        UI.message("Uploading '#{path}'...")

        begin
          meta_data = parse_meta_data(path)

          # Double checks that the app_identifier is as intended
          unless meta_data[:app_identifier] == Helper::UploadSymbolsToTpaHelper.app_identifier(params)
            raise "App identifier of dSYM path does not match app identifier specified in Fastfile"
          end

          # Constructs the url
          tpa_host = Helper::UploadSymbolsToTpaHelper.tpa_host(params)
          api_uuid = Helper::UploadSymbolsToTpaHelper.api_uuid(params)
          url = "#{tpa_host}/rest/api/v2/projects/#{api_uuid}/apps/#{meta_data[:app_identifier]}/versions/#{meta_data[:build]}/symbols/"

          # Uploads the dSYM to TPA
          RestClient.post(url, { version_string: meta_data[:version], mapping: File.new(path, 'rb') }, { :"X-API-Key" => params[:api_key] })
        rescue => ex
          UI.error(ex.to_s) # it fails, however we don't want to fail everything just for this
        end
      end

      #####################################################
      # @!group Documentation
      #####################################################

      def self.description
        "Upload dsym files downloaded from iTunesConnect directly to TPA"
      end

      def self.details
        [
          "If your app uses Bitcode, then the final dsym files are not generated upon compile time.",
          "Instead you have to go to iTunesConnect and downloade the dsym files after Apple has",
          "processed your app. Afterwards you need to upload these files to TPA in order to allow",
          "Thefor symbolication of the crash reports. You can use this plugin to streamline and",
          "automate this whole process."
        ].join(" ")
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(key: :dsym_path,
                                       env_name: "FL_UPLOAD_SYMBOLS_TO_TPA_DSYM_PATH",
                                       description: "Path to the DSYM zip file to upload",
                                       default_value: ENV[SharedValues::DSYM_OUTPUT_PATH.to_s] || (Dir["./**/*.dSYM.zip"]).sort_by { |f| File.mtime(f) }.last,
                                       default_value_dynamic: true,
                                       optional: true,
                                       verify_block: proc do |value|
                                         UI.user_error!("Couldn't find file at path '#{File.expand_path(value)}'") unless File.exist?(value)
                                         UI.user_error!("Symbolication file needs to be zip") unless value.end_with?(".zip")
                                       end),
          FastlaneCore::ConfigItem.new(key: :upload_url,
                                       env_name: "FL_TPA_UPLOAD_URL",
                                       description: "The TPA upload url",
                                       verify_block: proc do |value|
                                         UI.user_error!("Please pass your TPA Upload URL using `ENV['FL_TPA_UPLOAD_URL'] = 'value'`") unless value
                                       end),
          FastlaneCore::ConfigItem.new(key: :api_key,
                                       env_name: "FL_TPA_API_KEY",
                                       description: "An API key to TPA",
                                       verify_block: proc do |value|
                                         UI.user_error!("Please pass your TPA API key.using `ENV['FL_TPA_API_KEY'] = 'value'`") unless value
                                       end),
          FastlaneCore::ConfigItem.new(key: :app_identifier,
                                       short_option: "-a",
                                       env_name: "FL_TPA_APP_IDENTIFIER",
                                       description: "The bundle identifier of your app",
                                       optional: false,
                                       code_gen_sensitive: true,
                                       default_value: CredentialsManager::AppfileConfig.try_fetch_value(:app_identifier),
                                       default_value_dynamic: true)
        ]
      end

      def self.output
        nil
      end

      def self.return_value
        nil
      end

      def self.authors
        ["Stefan Veis Pennerup"]
      end

      def self.is_supported?(platform)
        [:ios].include?(platform)
      end

      def self.example_code
        [
          'upload_symbols_to_tpa(dsym_path: "./App.dSYM.zip")'
        ]
      end

      def self.category
        :misc
      end
    end
  end
end
