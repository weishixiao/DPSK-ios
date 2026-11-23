// Run with the repository's unchanged PhoneToolCatalog.kt and Json.kt.
import com.dpsk.harness.phone.PhoneToolCatalog
import com.dpsk.harness.phone.Json
fun main() { print(Json.write(PhoneToolCatalog.listJson())) }
