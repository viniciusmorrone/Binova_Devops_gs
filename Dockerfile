# Etapa 1 - build: compila a API Java com Maven e JDK 21
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY app/pom.xml .
RUN mvn -B -q dependency:go-offline
COPY app/src ./src
RUN mvn -B -q package -DskipTests

# Etapa 2 - runtime: apenas o JRE 21 e o .jar, executando com usuario nao-root
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S binova && adduser -S -G binova binova
WORKDIR /app
COPY --from=build /build/target/binova-0.0.1-SNAPSHOT.jar app.jar
RUN chown -R binova:binova /app
USER binova
ENV SERVER_PORT=8080 \
    JAVA_OPTS="-Xms256m -Xmx512m"
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
