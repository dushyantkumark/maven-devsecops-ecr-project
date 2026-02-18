FROM tomcat:10-jdk21-temurin-jammy
LABEL "Project"="Vprofile"
LABEL "Author"="HarishNShetty"

RUN groupadd -r tomcat && useradd -r -g tomcat tomcat \
    && rm -rf /usr/local/tomcat/webapps/*

WORKDIR /usr/local/tomcat/
COPY --chown=tomcat:tomcat target/vprofile-v2.war /usr/local/tomcat/webapps/ROOT.war

RUN chown -R tomcat:tomcat /usr/local/tomcat

USER tomcat
EXPOSE 8080
VOLUME /usr/local/tomcat/webapps
CMD ["catalina.sh", "run"]
