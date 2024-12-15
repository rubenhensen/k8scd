FROM httpd:2.4-bullseye
RUN apt-get update && \
    apt-get install --no-install-recommends -y \
    ca-certificates libapache2-mod-auth-openid
RUN touch /tmp/mod_auth_openid.db && chown www-data /tmp/mod_auth_openid.db
RUN mkdir /config
RUN touch /config/httpd.conf
RUN rm /usr/local/apache2/conf/httpd.conf
RUN ln -s /config/httpd.conf /usr/local/apache2/conf/httpd.conf

# how to build: docker build . -t hebury/sol-auth:2.3 
# how to push: docker push hebury/sol-auth:2.3
# do not remember how to build for arm atm.