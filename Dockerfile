FROM tomcat:10-jdk21-slim
LABEL "Project"="Vprofile"
LABEL "Author"="HarishNShetty"

WORKDIR /usr/local/tomcat/
RUN rm -rf /usr/local/tomcat/webapps/*
COPY --chown=root:root target/vprofile-v2.war /usr/local/tomcat/webapps/ROOT.war

USER nobody
EXPOSE 8080
CMD ["catalina.sh", "run"]
