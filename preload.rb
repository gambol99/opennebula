#!/usr/bin/ruby 
#
#   Author: Rohith
#   Date: 2013-10-29 10:10:32 +0100 (Tue, 29 Oct 2013)
#
#  vim:ts=4:sw=4:et
#
require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'optparse'
require 'timeout'
require 'pp'

# @TODO - this has been done very quickly to get things going, it needs to reworked and recoded 
Meta = {
    :prog     => "#{__FILE__}",       :author   => "Rohith",              
    :email    => "removed",           :date     => "2013-10-29 10:10:32 +0100",
    :version  => "0.0.2"
}

def usage( message ) 
    puts "\n%s\n" % [ Parser ] 
    if message
        puts "error: %s\n" % [ message ]
        exit 1
    end
    exit 0
end

def validate_integer( value, min, max, name, int = 0 )
    raise ArgumentError, "you must specify a name for the value"      unless name
    raise ArgumentError, "you have not specified a value for #{name}" unless value
    verbose "validate_integer: value: #{value} name: #{name} min: #{min} max: #{max} "
    unless value.is_a?( Integer) 
        raise ArgumentError, "#{name} is not a integer" unless value =~ /^[0-9]+$/  
    end
    value = value.to_i if value.is_a?( String )
    raise ArgumentError, "#{name} must be greater than #{min}" if value < min 
    raise ArgumentError, "#{name} must be less than #{max}"    if value > max   
    value
end

def validate_directory( directory, name = '' )
    raise ArgumentError, "you have not specified a directory for %s"     % [ name ] unless directory
    raise ArgumentError, "the directory #{directory} does not exist"     unless File.exist?( directory )
    raise ArgumentError, "the directory #{directory} is not a directory" unless File.directory?( directory )
    raise ArgumentError, "the directory #{directory} is not readable"    unless File.readable?( directory )
    raise ArgumentError, "the directory #{directory} is not writable"    unless File.writable?( directory )
    directory
end

def lock filename, lockfile = nil
    lock = {
        :filename => filename,
        :lockfile => lockfile || "%s.lock" % [ filename ],
        :lock     => nil,
        :success  => false
    }
    begin
        verbose "try_lock: attempting to acquire atomic lock for image %s, lock file: %s" % [ filename, lock[:lockfile] ]
        lock[:lock]    = File.open( lock[:lockfile], File::RDWR | File::CREAT, 0700 )
        lock[:success] = lock[:lock].flock( File::LOCK_NB|File::LOCK_EX )
    rescue Exception => e
        verbose "lock: exception trying to lock filename %s" % [ lock[:lockfile] ] 
        raise Exception, e.message
    end 
    lock  
end

def unlock lock 
    if lock[:lock]
        verbose "unlock: we are removing the lock for image: %s, lockfile: %s" % [ lock[:filename], lock[:lockfile] ]
        lock[:lock].flock( File::LOCK_UN ) 
        lock[:lock].close
        File.delete lock[:lockfile ]
    end
end

def preload_images_list directory = @options[:preload_dir], regex = @options[:preload_regex]
    available_files    = "%s/*" % [ directory]
    available_preloads = Dir.glob available_files
    # step: we need to filter out anything that isn't a image file
    available_preloads = available_preloads.select { |x| x =~ regex }
    available_preloads
end

def cache_image_list directory = @options[:cache_dir], regex = @options[:cache_regex]
    available_files  = "%s/*" % [ directory ]
    available_images =  Dir.glob available_files
    # step: we need to filter out anything that isn't a image file
    available_images = available_images.select { |x| x =~ regex }
    available_images
end

def clone image = @options[:source], destination = @options[:dest], size = @options[:disk_size] || 0, preload_dir = @options[:preload_dir]
    raise ArgumentError, "clone: you have not specified a image to clone"           unless image
    raise ArgumentError, "clone: you have not specified a destination to clone to"  unless destination
    preload_image = nil
    begin 
        image       = File.basename image
        # step: we have the image, lets get a list of available images in the preload directory
        available_preloads = preload_images_list 
        # step: filter for the image we want
        available_preloads = available_preloads.inject([]) do |a,x| 
            basename    = File.basename(x).split('.').first 
            if basename == image
                a << x
            end
            a
        end
        available_preloads.sort!
        verbose "clone: we have %d images listed: %s" % [ available_preloads.size, available_preloads.join(',') ]
        if available_preloads.empty?
            raise Exception, "clone: we have not preloaded image available at this time, we need to preload now"
        end
        # step: we iterate the list and try to lock one
        available_preloads.map do |image|
            verbose "clone: attempting to acquire the lock on preload image %s" [ image ]
            preload_image = lock image
            if !preload_image[:success]
                verbose "clone: the preload image %s is presently locked, skipping image" % [ preload_image[:filename] ]
                next
            else
                verbose "clone: we have acquired the preload image %s" % [ image ]
                break
            end
        end
        # step: were we able to acquire a image?
        unless preload_image[:success]
            raise Exception, "clone: all the preload images are presently locked, exitting"
        end
        # step: lets move and possibily resize
        verbose "clone: moving the preload image %s to destination %s" % [ preload_image[:filename], destination ]
        verbose( "/bin/mv %s %s" % [ preload_image[:filename], destination ] )
        system( "/bin/mv %s %s" % [ preload_image[:filename], destination ] )
        # step: do we have to resize the image
        if size > 0
            verbose "clone: resizing the image %s to %d gigs" % [ destination, size ]
            system( "/usr/bin/qemu-img resize %s +%dG" % [ destination, size ] )
            verbose( "/usr/bin/qemu-img resize %s +%dG" % [ destination, size ] )
        end
        verbose "clone: changing the owner to oneadmin:oneadmin on %s" % [ destination ]
        system( "/bin/chown oneadmin:oneadmin %s" % [ destination ] )
        verbose "clone: operation completed successfully"
    rescue Exception => e 
        verbose "clone: exception caught, error: %s" % [ e.message ]
        raise Exception, e.message
    ensure
        unlock preload_image if preload_image
    end
end

def preload cache_dir = @options[:cache_dir], preload_dir = @options[:preload_dir], size = @options[:preload_size]
    raise ArgumentError, "preload: you have not specified a cache_dir"      unless cache_dir
    raise ArgumentError, "preload: you have not specified a preload_dir"    unless preload_dir
    preload_lock = nil
    begin
        # step: get a list of the images in the cache
        images = cache_image_list
        raise Exception, "preload: we have not images available at this time" if images.empty?
        verbose "preload: we have %s images in the cache_dir: %s" % [ images.size, cache_dir ]
        # step: we only allow one preloading operation at a time, let lock
        preloading_lockfile = "%s/preload.lock" % [ cache_dir ]
        verbose "preload: attempting to acquire a lock for preloading, using lock %s" % [ preloading_lockfile ]
        preload_lock = lock preload_dir, preloading_lockfile
        unless preload_lock[:success]
            verbose "preload: the lock file %s is already locked, operation already in progress" % [ preloading_lockfile ]
            return
        end
        # step: iterate the images and copy them into the preload directory
        images.map do |image|
            image_file = File.basename image
            verbose "preload: cache image: %s" % [ image ]
            size.times.each do |instance|
                destination_file = "%s/%s.%d" % [ preload_dir, image_file, instance ]
                verbose "preload: checking for preload image %s" % [ destination_file ]
                if File.exists? destination_file
                    #verbose "preload: a preload image already %s exists, skipping file" % [ destination_file ]
                else
                    verbose "%10s" % [ 'copying' ]
                    verbose "preload: the preload image %s doesn't exist yet, copying over" % [ destination_file ]
                    preload_copying = nil
                    begin
                        # step: we need to create a atomic lock for this, as there will be a delay between the copying and we
                        # need to ensure a clone operation does not use the image before the images has been completely copied over
                        verbose "preload: attempting to acquire a lock for preload image: %s" % [ destination_file ]
                        preload_copying = lock destination_file
                        unless preload_copying[:success]
                            raise Exception, "preload: unable to acquire a lock for preload image %s" % [ destination_file ]
                        end
                        verbose "/bin/cp %s %s" % [ image, destination_file ] 
                        system( "/bin/cp %s %s" % [ image, destination_file ] )
                        verbose "preload: successfully made a preload copy, %s" % [ destination_file ]
                    rescue Exception => e 
                        verbose "preload: exception caught, error: %s" % [ e.message ]
                        raise Exception, e.message
                    ensure
                        unlock preload_copying if preload_copying
                    end
                end
            end
        end
    rescue Exception => e
        verbose "preload: exception caught, error: %s" % [ e.message ]
        raise Exception, e.message
    ensure
        unlock preload_lock if preload_lock 
    end
end

def verbose message = '', newline = true
    if @options[:verbose] and message
        vmesg = "%-21s: %-6s: %s" % [ Time.now.strftime( "%Y/%m/%d %T" ), '[verb]', message ]
        puts    "%s %s" % [ '[verb]', vmesg ] if newline
        printf  "%s" % [ vmesg ] unless newline
    end
end

Operations = [ 'preload', 'clone' ]

# 1e0f31828bfa3fa63257c501b36ad963
@options = {
    :preload_dir   => '/var/lib/one/cache',
    :preload_regex => /^.*\.[0-9]+$/, 
    :cache_dir     => '/var/lib/one/cache/100',
    :datastore     => '100'
    :cache_regex   => /^.*\/[[:alnum:]]{32}$/,
    :nice_io       => true,
    :preload_size  => 8,
    :operation     => 'preload',
    :disk_size     => 0,
    :source        => nil,
    :dest          => nil,
    :verbose       => false,
}
# lets get the options
Parser = OptionParser::new do |opts|
    opts.on( "-P", "--preload directory",   "the directory location of the preload store" )                          { |arg| @options[:preload_dir]  = arg   }
    opts.on( "-C", "--cache directory",     "the directory location of the cache store" )                            { |arg| @options[:cache_dir]    = arg   }
    opts.on( "-s", "--size number",         "the number of images to keep preloaded" )                               { |arg| @options[:preload_size] = arg   }
    opts.on( "-o", "--operation operation", "the operation you want to perform" )                                    { |arg| @options[:operation]    = arg   }
    opts.on( "--no_nice_io",                "by default we I/O nice the preloading" )                                {       @options[:nice_io]      = false }
    opts.on( "--src image",                 "the source image you wish to have a copy of" )                          { |arg| @options[:source]       = arg   }
    opts.on( "--dst dest",                  "the destination you want the image " )                                  { |arg| @options[:dest]         = arg   } 
    opts.on( "--size size",                 "resize the image to x, if zero, we leave it alone" )                    { |arg| @options[:disk_size]    = arg   }
    opts.on( "-v", "--verbose",             "switch on verbose logging" )                                            { |arg| @options[:verbose]      = true  }
end
Parser.parse!

# clone: Cloning open301-hsk.mol.dmgt.net:/var/lib/one//datastores/100/c8a6fd348b768536a93ae563b967f0fc in /var/lib/one/datastores/0/69/disk.0
begin 
    # step: validate the arguments
    unless Operations.include?( @options[:operation] )
        raise Exception, "the operation %s is not supported; supported operations are %s" % [ @options[:operation], Operations.join( ',' ) ] 
    end
    if @options[:operation] == 'preload'
        @options[:preload_dir]  = validate_directory( @options[:preload_dir], 'preload_dir' )
        @options[:cache_dir]    = validate_directory( @options[:cache_dir],   'cache_dir' )
        @options[:preload_size] = validate_integer( @options[:preload_size], 1, 10, 'preload_size' )
    else
        @options[:preload_dir]  = validate_directory( @options[:preload_dir], 'preload_dir' )
        raise Exception, "you have not specified a source image name"   unless @options[:source]
        raise Exception, "you have not specified a destination image"   unless @options[:dest]
        raise Exception, "you have not specified a disk size"           unless @options[:disk_size]
        raise Exception, "invalid disk size specified"                  unless @options[:disk_size] =~ /^([0-9]+)[Gg]?$/
        @options[:disk_size] = $1.to_i
        destination_dir = File.dirname( @options[:dest] )
        validate_directory( destination_dir, 'destination_dir' )
    end
rescue Exception => e 
    usage e.message
end

@lock = nil
begin
    # step: are we preloading or cloning
    preload if @options[:operation] == 'preload'
    if @options[:operation] == 'clone'
        clone 
    end
rescue SystemExit => e 
rescue Exception => e 
    usage "[error] %s" % [ e.message ]
end

