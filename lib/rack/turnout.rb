require 'rack'
require 'yaml'
require 'ipaddr'
require 'nokogiri'
require "builder"

class Rack::Turnout

  def initialize(app, config={})
    @app = app
    @config = config
  end

  def call(env)
    reload_settings

    if on?(env)
      if Rails.application.class.to_s.split("::")[0] == 'MobilnikConnector' || env['CONTENT_TYPE'] == 'application/xml'
        [200, {'Content-Type' => 'application/xml'}, [xml_content(env['action_dispatch.request.request_parameters'])]]
      elsif Rails.application.class.to_s.split("::")[0] == 'GeopayUssdConnector' || env['CONTENT_TYPE'] == 'application/json'
        [200, {'Content-Type' => 'application/json'}, [json_content]]
      else
        [503, {'Content-Type' => 'text/html', 'Content-Length' => content_length}, [content]]
      end
    else
      @app.call(env)
    end
  end

  protected

  def on?(env)
    request = Rack::Request.new(env)

    return false if path_allowed?(request.path)
    return false if ip_allowed?(request.ip)
    File.exists? settings_file
  end

  def path_allowed?(path)
    (settings['allowed_paths'] || []).each do |allowed_path|
      return true if path =~ Regexp.new(allowed_path)
    end
    false
  end

  def ip_allowed?(ip)
    ip = IPAddr.new(ip) unless ip.is_a? IPAddr
    (settings['allowed_ips'] || []).each do |allowed_ip|
      return true if IPAddr.new(allowed_ip).include? ip
    end
    false
  end

  def reload_settings
    @settings = nil
    settings
  end

  def settings
    @settings ||= if File.exists? settings_file
      YAML::load(File.open(settings_file)) || {}
    else
      {}
    end
  end

  def app_root
    @app_root ||= Pathname.new(
      @config[:app_root] || @app.respond_to?(:root)? @app.root.to_s : '.'
    )
  end

  def settings_file
    app_root.join('tmp', 'maintenance.yml')
  end

  def maintenance_page
    File.exists?(app_maintenance_page) ? app_maintenance_page : default_maintenance_page
  end

  def app_maintenance_page
    @app_maintenance_page ||= app_root.join('public', 'maintenance.html')
  end

  def default_maintenance_page
    @default_maintenance_page ||= File.expand_path('../../../public/maintenance.html', __FILE__)
  end

  def content_length
    content.size.to_s
  end

  def content
    content = File.open(maintenance_page, 'rb').read

    if settings['reason']
      html = Nokogiri::HTML(content)
      html.at_css('#reason').inner_html = settings['reason']
      content = html.to_s
    end

    content
  end

  def json_content
    {
      data: settings['reason'],
      last_message: true
    }.to_json
  end

  def xml_content(xml)
    message = {}
    message[:qid] = xml["XML"]["HEAD"]["QID"]
    message[:op]= xml["XML"]["HEAD"]["OP"]
    message[:dts]= Time.now.strftime("%Y-%m-%d %H:%M:%S")
    message[:reason] = settings["reason"] || "Down for maintenance, please try again later"

    build = Builder::XmlMarkup.new
    build.instruct! :xml, :version => "1.0", :encoding => "windows-1251"
    build.XML {
      build.HEAD("OP" => message[:op], "DTS" => message[:dts], "QID" => message[:qid])
      build.BODY("STATUS" => "1", "MSG" => settings["reason"])
    }
  end

end
