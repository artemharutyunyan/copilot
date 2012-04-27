use ExtUtils::MakeMaker;

WriteMakefile(
               'NAME'      => 'Copilot',
               'VERSION'   => '0.01',
               'PREREQ_PM' => {
                              	'POE'                          => "0.001",
                                'POE::Component::Jabber'       => "2.02",
                                'POE::Component::Logger'       => "1.00",
                                'XML::Simple'                  => "2.14",
				'XML::SAX::Expat::Incremental' => "0.05",
                                'Filesys::DiskFree'            => "0.06",
                                'Crypt::OpenSSL::RSA'          => "0.23",
                                'Crypt::CBC'                   => "2.21",
                                'Crypt::OpenSSL::AES'          => "0.01",
                                'MIME::Base64'                 => "2.04",
                              }
             );
