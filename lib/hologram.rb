# Copyright (c) 2013, Trulia, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#    * Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the Trulia, Inc. nor the
#      names of its contributors may be used to endorse or promote products
#      derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
# IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL TRULIA, INC. BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
# BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require "hologram/version"

require 'redcarpet'
require 'yaml'
require 'pygments'
require 'fileutils'
require 'pathname'
require 'erb'

require 'hologram_markdown_renderer'

module Hologram

  #Helper class for binding things for ERB
  class TemplateVariables
    attr_accessor :title, :file_name, :blocks

    def initialize(title, file_name, blocks)
      @title = title
      @file_name = file_name
      @blocks = blocks
    end

    def get_binding
      binding
    end
  end

  class DocumentBlock
    attr_accessor :name, :parent, :children, :title, :category, :markdown, :output_file, :config

    def initialize(config = nil, markdown = nil)
      @children = {}
      set_members(config, markdown) if config and markdown
    end

    def set_members(config, markdown)
      @name     = config['name']
      @parent   = config['parent']
      @category = config['category']
      @title    = config['title']
      @markdown = markdown
    end

    def get_hash
      {:name => @name,
       :parent => @parent,
       :category => @category,
       :title => @title
      }
    end

    def is_valid?
      @name && @markdown
    end
  end


  class Builder
    attr_accessor :doc_blocks, :config, :pages

    INIT_TEMPLATE_PATH = File.expand_path('./template/', File.dirname(__FILE__)) + '/'
    INIT_TEMPLATE_FILES = [
      INIT_TEMPLATE_PATH + '/hologram_config.yml',
      INIT_TEMPLATE_PATH + '/doc_assets',
    ]

    def init(args)
      @doc_blocks, @pages = {}, {}
      @supported_extensions = ['.css', '.scss', '.less', '.sass', '.styl', '.js', '.md', '.markdown' ]

      begin
        if args[0] == 'init' then

          if File.exists?("hologram_config.yml")
            puts "Cowardly refusing to overwrite existing hologram_config.yml"
          else
            FileUtils.cp_r INIT_TEMPLATE_FILES, Dir.pwd
            puts "Created the following files and directories:"
            puts "  hologram_config.yml"
            puts "  doc_assets/"
            puts "  doc_assets/_header.html"
            puts "  doc_assets/_footer.html"
          end
        else
          begin
            config_file = args[0] ? args[0] : 'hologram_config.yml'

            begin
              @config = YAML::load_file(config_file)
            rescue
              display_error "Could not load config file, try hologram init to get started"
            end

            validate_config

            #TODO: maybe this should move into build_docs
            current_path = Dir.pwd
            base_path = Pathname.new(config_file)
            Dir.chdir(base_path.dirname)

            build_docs

            Dir.chdir(current_path)
            puts "Build completed. (-: ".green
          rescue RuntimeError => e
            display_error("#{e}")
          end
        end
      end
    end


    private
    def build_docs
      # Create the output directory if it doesn't exist
      FileUtils.mkdir_p(config['destination']) unless File.directory?(config['destination'])

      begin
        input_directory  = Pathname.new(config['source']).realpath
      rescue
        display_error "Can not read source directory, does it exist?"
      end

      output_directory = Pathname.new(config['destination']).realpath
      doc_assets       = Pathname.new(config['documentation_assets']).realpath unless !File.directory?(config['documentation_assets'])

      if doc_assets.nil?
        display_warning "Could not find documentation assets at #{config['documentation_assets']}"
      end

      process_dir(input_directory)

      build_pages_from_doc_blocks(@doc_blocks)

      # if we have an index category defined in our config copy that
      # page to index.html
      if config['index']
        if @pages.has_key?(config['index'] + '.html')
          @pages['index.html'] = @pages[config['index'] + '.html']
        else
          display_warning "Could not generate index.html, there was no content generated for the category #{config['index']}."
        end
      end

      write_docs(output_directory, doc_assets)

      # Copy over dependencies
      if config['dependencies']
        config['dependencies'].each do |dir|
          begin
            dirpath  = Pathname.new(dir).realpath
            if File.directory?("#{dir}")
              `rm -rf #{output_directory}/#{dirpath.basename}`
              `cp -R #{dirpath} #{output_directory}/#{dirpath.basename}`
            end
          rescue
            display_warning "Could not copy dependency: #{dir}"
          end
        end
      end

      if !doc_assets.nil?
        Dir.foreach(doc_assets) do |item|
         # ignore . and .. directories and files that start with
         # underscore
         next if item == '.' or item == '..' or item.start_with?('_')
         `rm -rf #{output_directory}/#{item}`
         `cp -R #{doc_assets}/#{item} #{output_directory}/#{item}`
        end
      end
    end


    def process_dir(base_directory)
      #get all directories in our library folder
      directories = Dir.glob("#{base_directory}/**/*/")
      directories.unshift(base_directory)

      directories.each do |directory|
        # filter and sort the files in our directory
        files = []
        Dir.foreach(directory).select{ |file| is_supported_file_type?(file) }.each do |file|
          files << file
        end
        files.sort!
        process_files(files, directory)
      end
    end


    def process_files(files, directory)
      files.each do |input_file|
        if input_file.end_with?('md')
          @pages[File.basename(input_file, '.md') + '.html'] = {:md => File.read("#{directory}/#{input_file}"), :blocks => []}
        else
          process_file("#{directory}/#{input_file}")
        end
      end
    end


    def process_file(file)
      file_str = File.read(file)
      # get any comment blocks that match the patterns:
      # .sass: //doc (follow by other lines proceeded by a space)
      # other types: /*doc ... */
      if file.end_with?('.sass')
        hologram_comments = file_str.scan(/\s*\/\/doc\s*((( [^\n]*\n)|\n)+)/)
      else
        hologram_comments = file_str.scan(/^\s*\/\*doc(.*?)\*\//m)
      end
      return unless hologram_comments

      hologram_comments.each do |comment_block|
        doc_block = build_doc_block(comment_block[0])
        add_doc_block_to_collection(doc_block) if doc_block
      end
    end


    # this should throw an error if we have a match, but now yaml_match
    def build_doc_block(comment_block)
      yaml_match = /^\s*---\s(.*?)\s---$/m.match(comment_block)
      return unless yaml_match
      markdown = comment_block.sub(yaml_match[0], '')

      begin
        config = YAML::load(yaml_match[1])
      rescue
        display_error("Could not parse YAML:\n#{yaml_match[1]}")
      end

      if config['name'].nil?
        puts "Missing required name config value. This hologram comment will be skipped. \n #{config.inspect}"
      else
        doc_block = DocumentBlock.new(config, markdown)
      end
    end


    def add_doc_block_to_collection(doc_block)
      return unless doc_block.is_valid?
      if doc_block.parent.nil?
        #parent file
        begin
          doc_block.output_file = get_file_name(doc_block.category)
        rescue NoMethodError => e
          display_error("No output file specified. Missing category? \n #{doc_block.inspect}")
        end

        @doc_blocks[doc_block.name] = doc_block;
        doc_block.markdown = "\n\n<#{@config['parent_heading_tag']} id=\"#{doc_block.name}\">#{doc_block.title}</#{@config['parent_heading_tag']}>" + doc_block.markdown
      else
        # child file
        parent_doc_block = @doc_blocks[doc_block.parent]
        if parent_doc_block
          if doc_block.title.nil?
            doc_block.markdown = doc_block.markdown
          else
            doc_block.markdown = "\n\n<#{@config['child_heading_tag']} id=\"#{doc_block.name}\">#{doc_block.title}</#{@config['child_heading_tag']}>" + doc_block.markdown
          end
          parent_doc_block.children[doc_block.name] = doc_block
        else
          @doc_blocks[doc_block.parent] = DocumentBlock.new()
        end
      end
    end


    def build_pages_from_doc_blocks(doc_blocks, output_file = nil)
      doc_blocks.sort.map do |key, doc_block|
        output_file = doc_block.output_file || output_file

        if !@pages.has_key?(output_file)
          @pages[output_file] = {:md => "", :blocks => []}
        end

        @pages[output_file][:blocks].push(doc_block.get_hash)
        @pages[output_file][:md] << doc_block.markdown
        if doc_block.children
          build_pages_from_doc_blocks(doc_block.children, output_file)
        end
      end
    end


    def write_docs(output_directory, doc_assets)
      # load the markdown renderer we are going to use
      renderer = get_markdown_renderer

      if File.exists?("#{doc_assets}/_header.html")
        header_erb = ERB.new(File.read("#{doc_assets}/_header.html"))
      elsif File.exists?("#{doc_assets}/header.html")
        header_erb = ERB.new(File.read("#{doc_assets}/header.html"))
      else
        header_erb = nil
        display_warning "No _header.html found in documentation assets. Without this your css/header will not be included on the generated pages."
      end

      if File.exists?("#{doc_assets}/_footer.html")
        footer_erb = ERB.new(File.read("#{doc_assets}/_footer.html"))
      elsif File.exists?("#{doc_assets}/footer.html")
        footer_erb = ERB.new(File.read("#{doc_assets}/footer.html"))
      else
        footer_erb = nil
        display_warning "No _footer.html found in documentation assets. This might be okay to ignore..."
      end

      #generate html from markdown
      @pages.each do |file_name, page|
        fh = get_fh(output_directory, file_name)

        title = page[:blocks].empty? ? "" : page[:blocks][0][:category]

        tpl_vars = TemplateVariables.new title, file_name, page[:blocks]

        # generate doc nav html
        unless header_erb.nil?
          fh.write(header_erb.result(tpl_vars.get_binding))
        end

        # write the docs
        fh.write(renderer.render(page[:md]))

        # write the footer
        unless footer_erb.nil?
          fh.write(footer_erb.result(tpl_vars.get_binding))
        end

        fh.close()
      end
    end


    def get_markdown_renderer
      if config['custom_markdown'].nil?
        renderer = Redcarpet::Markdown.new(HologramMarkdownRenderer, { :fenced_code_blocks => true, :tables => true })
      else
        begin
          load config['custom_markdown']
          renderer_class = File.basename(config['custom_markdown'], '.rb').split(/_/).map(&:capitalize).join
          puts "Custom markdown renderer #{renderer_class} loaded."
          renderer = Redcarpet::Markdown.new(Module.const_get(renderer_class), { :fenced_code_blocks => true, :tables => true })
        rescue LoadError => e
          display_error("Could not load #{config['custom_markdown']}.")
        rescue NameError => e
          display_error("Class #{renderer_class} not found in #{config['custom_markdown']}.")
        end
      end
      renderer
    end


    def validate_config
      unless @config.key?('source')
        display_error "No source directory specified in the config file"
      end

      unless @config.key?('destination')
        display_error "No destination directory specified in the config"
      end

      unless @config.key?('documentation_assets')
        display_error "No documentation assets directory specified"
      end

      #Setup some defaults for these guys
      unless @config.key?('parent_heading_tag')
        @config['parent_heading_tag'] = 'h1'
      end

      unless @config.key?('child_heading_tag')
        @config['child_heading_tag'] = 'h2'
      end
    end


    def is_supported_file_type?(file)
      @supported_extensions.include?(File.extname(file))
    end

    def display_error(message)
      if RUBY_VERSION.to_f > 1.8 then
        puts "(\u{256F}\u{00B0}\u{25A1}\u{00B0}\u{FF09}\u{256F}".green + "\u{FE35} \u{253B}\u{2501}\u{253B} ".yellow + " Build not complete.".red
      else
        puts "Build not complete.".red
      end
        puts " #{message}"
        exit 1
    end

    def display_warning(message)
      puts "Warning: ".yellow + message
    end


    def get_file_name(str)
      str = str.gsub(' ', '_').downcase + '.html'
    end


    def get_fh(output_directory, output_file)
      File.open("#{output_directory}/#{output_file}", 'w')
    end
  end

end


class String
  # colorization
  def colorize(color_code)
    "\e[#{color_code}m#{self}\e[0m"
  end

  def red
    colorize(31)
  end

  def green
    colorize(32)
  end

  def yellow
    colorize(33)
  end

  def pink
    colorize(35)
  end
end
