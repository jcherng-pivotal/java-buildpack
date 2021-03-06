# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'java_buildpack'
require 'java_buildpack/buildpack_version'
require 'java_buildpack/component/additional_libraries'
require 'java_buildpack/component/application'
require 'java_buildpack/component/droplet'
require 'java_buildpack/component/immutable_java_home'
require 'java_buildpack/component/java_opts'
require 'java_buildpack/component/mutable_java_home'
require 'java_buildpack/logging/logger_factory'
require 'java_buildpack/util/configuration_utils'
require 'java_buildpack/util/constantize'
require 'java_buildpack/util/snake_case'
require 'java_buildpack/util/space_case'
require 'pathname'

module JavaBuildpack

  # Encapsulates the detection, compile, and release functionality for Java application
  class Buildpack

    # Iterates over all of the components to detect if this buildpack can be used to run an application
    #
    # @return [Array<String>] An array of strings that identify the components and versions that will be used to run
    #                         this application.  If no container can run the application, the array will be empty
    #                         (+[]+).
    def detect
      tags = tag_detection('container', @containers, true)
      tags.concat tag_detection('JRE', @jres, true) unless tags.empty?
      tags.concat tag_detection('framework', @frameworks, false) unless tags.empty?
      tags << "java-buildpack=#{@buildpack_version.to_s false}" unless tags.empty?
      tags = tags.flatten.compact.sort

      @logger.debug { "Detection Tags: #{tags}" }
      tags
    end

    # Transforms the application directory such that the JRE, container, and frameworks can run the application
    #
    # @return [Void]
    def compile
      puts BUILDPACK_MESSAGE % @buildpack_version

      container = component_detection(@containers).first
      puts container
      fail 'No container can run this application' unless container

      component_detection(@jres).first.compile
      component_detection(@frameworks).each { |framework| framework.compile }
      container.compile
    end

    # Generates the payload required to run the application.  The payload format is defined by the
    # {Heroku Buildpack API}[https://devcenter.heroku.com/articles/buildpack-api#buildpack-api].
    #
    # @return [String] The payload required to run the application.
    def release
      container = component_detection(@containers).first
      fail 'No container can run this application' unless container

      component_detection(@jres).first.release
      component_detection(@frameworks).each { |framework| framework.release }
      command = container.release

      payload = {
        'addons'                => [],
        'config_vars'           => {},
        'default_process_types' => { 'web' => command }
      }.to_yaml

      @logger.debug { "Release Payload #{payload}" }

      payload
    end

    private_class_method :new

    private

    BUILDPACK_MESSAGE = '-----> Java Buildpack Version: %s'.freeze

    LOAD_ROOT = (Pathname.new(__FILE__).dirname + '..').freeze

    private_constant :BUILDPACK_MESSAGE, :LOAD_ROOT

    def initialize(app_dir, application)
      @logger            = Logging::LoggerFactory.instance.get_logger Buildpack
      @buildpack_version = BuildpackVersion.new

      log_environment_variables

      additional_libraries = Component::AdditionalLibraries.new app_dir
      mutable_java_home    = Component::MutableJavaHome.new
      immutable_java_home  = Component::ImmutableJavaHome.new mutable_java_home, app_dir
      java_opts            = Component::JavaOpts.new app_dir

      components = JavaBuildpack::Util::ConfigurationUtils.load 'components'

      @jres       = instantiate(components['jres'], additional_libraries, application, mutable_java_home, java_opts,
                                app_dir)
      @frameworks = instantiate(components['frameworks'], additional_libraries, application, immutable_java_home,
                                java_opts, app_dir)
      @containers = instantiate(components['containers'], additional_libraries, application, immutable_java_home,
                                java_opts, app_dir)
    end

    def component_detection(components)
      components.select { |component| component.detect }
    end

    def instantiate(components, additional_libraries, application, java_home, java_opts, root)
      components.map do |component|
        @logger.debug { "Instantiating #{component}" }

        require_component(component)

        component_id = component.split('::').last.snake_case
        context      = {
          application:   application,
          configuration: Util::ConfigurationUtils.load(component_id),
          droplet:       Component::Droplet.new(additional_libraries, component_id, java_home, java_opts, root)
        }

        component.constantize.new(context)
      end
    end

    def log_environment_variables
      @logger.debug { "Environment Variables: #{ENV.to_hash}" }
    end

    def names(components)
      components.map { |component| component.class.to_s.space_case }.join(', ')
    end

    def require_component(component)
      file = LOAD_ROOT + "#{component.snake_case}.rb"

      if file.exist?
        require(component.snake_case)
        @logger.debug { "Successfully required #{component}" }
      else
        @logger.debug { "Cannot require #{component} because #{file} does not exist" }
      end
    end

    def tag_detection(type, components, unique)
      detected = []
      tags     = []

      components.each do |component|
        result = component.detect

        if result
          detected << component
          tags << result
        end
      end

      fail "Application can be run by more than one #{type}: #{names detected}" if unique && tags.size > 1
      tags
    end

    class << self

      # Main entry to the buildpack.  Initializes the buildpack and all of its dependencies and yields a new instance
      # to any given block.  Any exceptions thrown as part of the buildpack setup or execution are handled
      #
      # @param [String] app_dir the path of the application directory
      # @param [String] message an error message with an insert for the reason for failure
      # @yield [Buildpack] the buildpack to work with
      # @return [Object] the return value from the given block
      def with_buildpack(app_dir, message)
        app_dir     = Pathname.new(File.expand_path(app_dir))
        application = Component::Application.new(app_dir)
        Logging::LoggerFactory.instance.setup app_dir

        yield new(app_dir, application) if block_given?
      rescue => e
        handle_error(e, message)
      end

      private

      def handle_error(e, message)
        if Logging::LoggerFactory.instance.initialized
          logger = Logging::LoggerFactory.instance.get_logger Buildpack

          logger.error { message % e.inspect }
          logger.debug { "Exception #{e.inspect} backtrace:\n#{e.backtrace.join("\n")}" }
        end

        abort e.message
      end

    end

  end

end
