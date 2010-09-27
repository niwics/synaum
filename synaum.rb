#!/usr/bin/ruby
require 'net/ftp'

class Synaum

  POSSIBLE_PARAMS = ['l', 'b']

  @error = false

  @website
  @src_dir
  @params

  @local = false
  @backward = false

  @ftp
  @ftp_dir
  @username
  @password
  @local_dir
  @modules
  @exclude_modules

  @config_dir
  @dst_dir
  @last_date

  def initialize
    # default values
    @local_dir = ''
    @modules = ['@gorazd-system']
    @last_date = Time.mktime(1970, 1, 1)
    parse_params
    if !@error
      @src_dir = get_website_dir(@website)
    end
    if !@error
      load_settings
    end
  end



  # parse params
  def parse_params
    param1 = ARGV.shift
    if !param1
      return err 'Nebyl zadán název webu pro synchronizaci.'
    end
    if param1[0,1] == '-'
      @params = param1
      @website = ARGV.shift
      if !@website
        return err 'Nebyl zadán název webu pro synchronizaci.'
      end
    else
      @website = param1
      @params = ARGV.shift
    end
    # check possible params
    if @params != nil
      @params = @params[1..-1] #TODO frozen...
      @params.each_char do |i|
        case i
        when 'l':
          @local = true
        when 'b':
          @backward = true
        else
          echo 'Zadán neplatný přepínač: "' + i + '".'
          return err 'Povolené přepínače: ' + POSSIBLE_PARAMS.join('') + '.'
        end
      end
    else
      @params = ''
    end
    return true
  end



  # check for the existency of selected website
  def get_website_dir (website)
    if website.index('/') # - was the website name set with a path?
      return website
    else
      # try to select the website from the parent folder
      orig_path = Dir.pwd
      Dir.chdir(File.dirname(__FILE__))
      Dir.chdir('..')
      src_dir = Dir.pwd+'/'+website
      Dir.chdir(orig_path)
      if !File.exist?(src_dir)
        # try to load path from the config file
        puts src_dir
        if @config_dir != nil
          src_dir = @config_dir+'/'+website
        elsif !File.exist?("config")
          @config_dir = false # for future use
          echo 'Nepodařilo se najít složku "'+ src_dir +'" pro provedení synchronizace webu "'+ website +'", ani nebyl nalezen soubor "config", odkud by bylo možné načíst cestu k této složce.'
          return err "Možné zadání cesty ke složce:\n - jako parametr skriptu (např. /work/my-website)\n - v parametru jen název složky např. my-website)\n     - a tato složka musí být umístěna vedle složky se tímto Synaum skriptem\n     - NEBO cesta musí být zadána v souboru config umístěném vedl tohoto Synaum skriptu."
        else
          # load value from config file
          config_file = File.open("config")
          while line = config_file.gets
            line.chomp!
            if line[0,1] != '#'
              @config_dir = line
              src_dir = @config_dir+'/'+website
              break
            end
          end
          if !File.exist?(src_dir)
            return err 'Nebyla nalezena složka "'+ src_dir +'" pro provedení synchronizace webu "' + website + '".'
          end
        end
      end
    end
    return src_dir
  end



  def load_settings
    # load data from the config file
    Dir.chdir(@src_dir)
    if !File.exist?('synaum')
      return err 'Nebyl nalezen soubor "synaum" potřebný k synchronizaci webu "'+ @website +'".'
    end
    synaum_file = File.open('synaum')
    while line = synaum_file.gets
      line.chomp!
      if line[0,1] != '#' and line != ''
        values = line.split(' ')
        case values[0]
          when 'ftp' then @ftp = values[1]
          when 'ftp-dir' then @ftp_dir = values[1]
          when 'username' then @username = values[1]
          when 'password' then @password = values[1]
          when 'local-dir' then @local_dir = values[1]
          when 'modules' then @modules = values[1]
          when 'exclude-modules' then @exclude_modules = values[1]
        end
      end
    end
    
    # set modes
    if @params.index('l')
      echo 'Lokální synchronizace webu "'+ @website +'"...'
      @local = true
    end
    if @params.index('b')
      @backward = true
    end
    return true
  end


  
  def synchronize
    @src_dir = @src_dir + '/www'
    if @local
      synchronize_local
    else
      synchronize_remote
    end
    return true
  end


  def synchronize_local
    @dst_dir = @local_dir

    # check existency of local folder
    if !@dst_dir
      return err 'Nebyla zadána cesta pro lokální režim (= hodnota "path" v konfiguračním souboru "'+ @src_dir +'/synaum")'
    end
    separ = @local_dir.rindex(File::SEPARATOR) - 1
    local_parent = @local_dir[0..separ]
    if !File.exists?(local_parent)
      return err 'Výstupní složka "'+ local_parent +'" pro synchronizaci na localhostu neexistuje.'
    end
    if !File.writable?(local_parent)
      return err 'Nemáte oprávnění pro zápis do složky "'+ local_parent +'".'
    end

    # check the local directory
    if !File.exist?(@dst_dir)
      Dir.mkdir(@dst_dir, 0775)
    end

    # try to load the file with last modification date
    last_filename = @dst_dir + '/' + 'synaum-last'
    if File.exist?(last_filename)
      last_file = File.open(last_filename)
      while line = last_file.gets
        line.chomp!
        if line[0,1] != '#' and line != ''
          @last_date = Time.marshal_load(line)
        end
      end
    end

    # do synchronization
    sync_modules
    return sync('/', true)
  end


  def synchronize_remote
    @dst_dir = @ftp_dir+'/'+@website
    # connect to FTP
    ftp = Net::FTP.new
    ftp.connect(server_name)
    ftp.login(username, password)
    ftp.chdir(directory)
    ftp.getbinaryfile(filename)
    ftp.close
  end


  def sync_modules
    # create module dir if not exists
    if !File.exist?(@dst_dir+'/modules')
      Dir.mkdir(@dst_dir+'/modules', 0775)
    end

    # modules from the website
    sync('/modules/')
    # other modules
    @modules.each do |mod|
      # get module path and module_name
      path, name = mod.split('@')
      
      puts path + '...' + name
    end
  end


  
  def sync (dir, is_root = false)
    Dir.foreach(@src_dir + dir) do |file|
      if file != '.' and file != '..' and (!is_root or file != 'modules')
        if @local
          if !File.exist?(@dst_dir+dir+file)
            File.symlink(@src_dir+dir+file, @dst_dir+dir+file)
          end
        elsif File.file?(@src_dir+dir+file)
          # check existency and modification time
          if !file_exists(dir+file)
            file_move(dir+file)
          elsif file_modified(dir+file)
            puts 'REMOTE-MODIFIED: '+ dir+file
          elsif File.stat(@src_dir+dir+file).mtime > @last_date
            file_move(dir+file)
          end
        else
          exists_create dir+file
          sync(dir + file + '/')
        end
      end
    end
  end


  def file_exists (file)
    return @local ? File.exist?(@dst_dir+file) : false
  end


  def file_modified (file)
    if @local
      return File.stat(@dst_dir+file).mtime > @last_date
    end
    return false
  end


  def file_move (file)
    puts '--copy--'+file
  end


  # Returns true when new dir was created
  def exists_create (dir)
    if !@local
      return err 'nedodelano exists_create pro FTP'
    end
    
    if File.exist?(@dst_dir + dir)
      echo "DIR existuje "+@dst_dir + dir
    else
      echo "DIR vytvarim... "+@dst_dir + dir
      if @local
        File.symlink(@src_dir + dir, @dst_dir + dir)
      else
        Dir.mkdir(@dst_dir + dir, 0775)
        return err 'NEIMPLEMENTOVANO - vytvareni dir v exists_create'
      end
    end
  end


  def is_error?
    return @error
  end


  def err (message)
    echo message
    @error = true
    return false
  end


  def echo (message)
    puts "> " + message
  end


  def print_result_message
    if @error
      echo 'Synchronizace nebyla provedena.'
    else
      echo 'Synchronizace proběhla úspěšně'
    end
  end
end



synaum = Synaum.new()
if !synaum.is_error?
  synaum.synchronize
end
synaum.print_result_message