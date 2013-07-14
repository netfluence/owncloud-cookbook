#
# Cookbook Name:: owncloud
# Recipe:: default
#
# Copyright 2013, Onddo Labs, Sl.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

::Chef::Recipe.send(:include, Opscode::OpenSSL::Password)

include_recipe 'php'
include_recipe 'apache2::default'
include_recipe 'apache2::mod_php5'
include_recipe 'database::mysql'
include_recipe 'mysql::server'

if Chef::Config[:solo]
  if node['owncloud']['config']['dbpassword'].nil? or
    node['owncloud']['admin']['pass'].nil?
    Chef::Application.fatal!(
      'You must set owncloud\'s database and admin passwords in chef-solo mode.'
    )
  end
else
  node.set_unless['owncloud']['config']['dbpassword'] = secure_password
  node.set_unless['owncloud']['admin']['pass'] = secure_password
  node.save
end

%w{ php5-mysql php5-gd }.each do |pkg|
  package pkg do
    action :install
  end
end

mysql_connection_info = {
  :host => 'localhost',
  :username => 'root',
  :password => node['mysql']['server_root_password']
}

mysql_database node['owncloud']['config']['dbname'] do
  connection mysql_connection_info
  action :create
end

mysql_database_user node['owncloud']['config']['dbuser'] do
  connection mysql_connection_info
  database_name node['owncloud']['config']['dbname']
  host 'localhost'
  password node['owncloud']['config']['dbpassword']
  privileges [:all]
  action :grant
end

directory node['owncloud']['www_dir']

basename = ::File.basename(node['owncloud']['download_url'])

execute "extract owncloud" do
  command <<-EOF
      tar xfj '#{::File.join(Chef::Config[:file_cache_path], basename)}' \
      --no-same-owner
    EOF
  cwd node['owncloud']['www_dir']
  action :nothing
end

remote_file "download owncloud" do
  source node['owncloud']['download_url']
  path ::File.join(Chef::Config[:file_cache_path], basename)
  action :create_if_missing
  notifies :run, "execute[extract owncloud]", :immediately
end

[
  ::File.join(node['owncloud']['dir'], 'apps'),
  ::File.join(node['owncloud']['dir'], 'config'),
  node['owncloud']['data_dir']
].each do |dir|
  directory dir do
    owner node['apache']['user']
    group node['apache']['group']
    mode 00750
    action :create
  end
end

web_app 'owncloud' do
  template 'vhost.erb'
  docroot node['owncloud']['dir']
  server_name node['owncloud']['server_name']
  port '80'
  enable true
end

if node['owncloud']['ssl']
  include_recipe 'apache2::mod_ssl'
  package 'ssl-cert' # generates a self-signed (snakeoil) certificate

  web_app 'owncloud-ssl' do
    template 'vhost.erb'
    docroot node['owncloud']['dir']
    server_name node['owncloud']['server_name']
    port '443'
    enable true
  end
end

template 'autoconfig.php' do
  path ::File.join(node['owncloud']['dir'], 'config', 'autoconfig.php')
  source 'autoconfig.php.erb'
  owner node['apache']['user']
  group node['apache']['group']
  mode 00640
  variables(
    :dbtype => node['owncloud']['config']['dbtype'],
    :dbname => node['owncloud']['config']['dbname'],
    :dbuser => node['owncloud']['config']['dbuser'],
    :dbpass => node['owncloud']['config']['dbpassword'],
    :dbhost => node['owncloud']['config']['dbhost'],
    :dbprefix => node['owncloud']['config']['dbtableprefix'],
    :admin_user => node['owncloud']['admin']['user'],
    :admin_pass => node['owncloud']['admin']['pass'],
    :data_dir => node['owncloud']['data_dir']
  )
  not_if { ::File.exists?(::File.join(node['owncloud']['dir'], 'config', 'config.php')) }
  notifies :restart, "service[apache2]", :immediately
  notifies :get, "http_request[run setup]", :immediately
end

http_request "run setup" do
  url "http://localhost/"
  message ''
  action :nothing
end

ruby_block "apply config" do
  block do
    config_file = ::File.join(node['owncloud']['dir'], 'config', 'config.php')
    config = OwnCloud::Config.new(config_file)
    # exotic case: change dbtype when sqlite3 driver is available
    if node['owncloud']['config']['dbtype'] == 'sqlite' and config['dbtype'] == 'sqlite3'
      node['owncloud']['config']['dbtype'] == config['dbtype']
    end
    config.merge(node['owncloud']['config'])
    config.write
    unless Chef::Config[:solo]
      # store important options that where generated automatically by the setup
      node.set_unless['owncloud']['config']['passwordsalt'] = config['passwordsalt']
      node.set_unless['owncloud']['config']['instanceid'] = config['instanceid']
      node.save
    end
  end
end
